//! x86 machine setup policy.

const std = @import("std");
const kvm = @import("kvm");
const GuestMemory = @import("../../memory.zig").GuestMemory;
const VmConfig = @import("../../root.zig").VmConfig;
const Vm = @import("../../root.zig").Vm;
const posix = std.posix;
const Allocator = std.mem.Allocator;
const gdt = @import("gdt.zig");
const paging = @import("paging.zig");
const mmap = @import("test_utils").mmap;
const VmConsoleConfig = @import("../../root.zig").VmConsoleConfig;
const IdAllocator = @import("utils").IdAlloc.IdAllocator;
const acpi = @import("acpi.zig");
const Snapshot = @import("../../snapshot/root.zig").Snapshot;
const MmioAlloc = @import("../../device/mmio_alloc.zig").MmioAlloc;
const kvm_system = &@import("../../root.zig").kvm_system;
const memory = @import("../../memory.zig");

pub const ArchVcpuState = @import("vcpu.zig").ArchVcpuState;
pub const snapshot_cpu = @import("vcpu.zig").snapshot_cpu;
pub const restore_cpu = @import("vcpu.zig").restore_cpu;
pub const DeviceBus = @import("device_bus.zig");
pub const layout = @import("layout.zig");
const DEFAULT_CMD_LINE: []const u8 = "console=ttyS0 earlycon=uart,io,0x3f8 nokaslr panic=-1 reboot=t";

// Long-mode enable
const EFER_LME = 1 << 8;

// Long-mode active
const EFER_LMA = 1 << 10;

// Enable paging
const CR0_PG = 1 << 31;

// Protected mode
const CR0_PE = 1 << 0;

// Enable paging
const CR4_PAE = 1 << 5;

pub fn setup_bs_vcpu(vcpu: *kvm.vcpu.Vcpu, ep: u64) !void {
    {
        var sregs = try vcpu.get_sregs();

        // Setup segments. This setups cached version of GDT
        gdt.setup_segment(&sregs.cs, true, gdt.GDT_CODE_INDEX);
        gdt.setup_segment(&sregs.ds, false, gdt.GDT_DATA_INDEX);
        gdt.setup_segment(&sregs.ss, false, gdt.GDT_DATA_INDEX);
        gdt.setup_segment(&sregs.gs, false, gdt.GDT_DATA_INDEX);
        gdt.setup_segment(&sregs.fs, false, gdt.GDT_DATA_INDEX);
        gdt.setup_segment(&sregs.es, false, gdt.GDT_DATA_INDEX);

        // Enable long mode
        sregs.efer = EFER_LME | EFER_LMA;

        // Enable paging
        sregs.cr0 = CR0_PG | CR0_PE;

        // Enable physical address extension
        sregs.cr4 = CR4_PAE;

        // Enable physical address extension
        sregs.cr3 = layout.PGD_ADDR;

        try vcpu.set_sregs(&sregs);
    }

    {
        var sregs = try vcpu.get_sregs2();

        sregs.gdt.base = layout.GDT_ADDR;
        sregs.gdt.limit = 31;

        try vcpu.set_sregs2(&sregs);
    }

    var regs = try vcpu.get_regs();
    regs.rip = ep;
    regs.rsi = layout.BOOT_PARAM_ADDR;
    try vcpu.set_regs(&regs);
}

pub const IrqAllocator = IdAllocator(16);

pub const ArchVm = struct {
    device_bus: DeviceBus,
    irqs: IrqAllocator,
    mmio_alloc: MmioAlloc,
    vm: kvm.Vm,
    memory: *memory.GuestMemory,
    ram_size: usize,

    const Self = @This();

    pub fn new(
        ram_size: usize,
        pci: bool,
        alloc: Allocator,
        io: std.Io,
    ) !Self {
        const system = try kvm_system.get();

        // Create empty KVM VM
        var vm = try system.create_vm();
        errdefer vm.deinit();

        // Empty guest memory
        var mem = try memory.GuestMemory.new(alloc);
        errdefer mem.deinit(alloc);

        const mem_layout = layout.memory_layout(ram_size);

        var idalloc = IrqAllocator{};

        // Reserve IRQ for com1
        _ = idalloc.allocate_specific(4).?;

        // Reserve IRQ for com2
        _ = idalloc.allocate_specific(3).?;

        // Reserve IRQ for PIT
        _ = idalloc.allocate_specific(0).?;

        // Reserve IRQ for PIC cascade
        _ = idalloc.allocate_specific(2).?;

        const pci_range = if (pci) mem_layout.pci_range() else null;

        try vm.create_irqchip();
        try vm.create_pit();

        try Self.setup_memory(mem, &mem_layout, alloc);
        try Self.setup_pagetables(mem);

        // Map regions into kvm
        for (mem.get_regions()) |reg| {
            try vm.set_user_memory_region(reg.gpa, reg.slot, reg.raw);
        }

        return .{
            .vm = vm,
            .memory = mem,
            .ram_size = ram_size,
            .device_bus = try DeviceBus.new(pci_range, alloc, io),
            .irqs = idalloc,
            .mmio_alloc = MmioAlloc.new(mem_layout.mmio_space()),
        };
    }

    pub fn from_snapshot(
        state: *const ArchVmState,
        alloc: std.mem.Allocator,
        io: std.Io,
    ) !Self {
        const system = try kvm_system.get();

        // Create empty KVM VM
        var vm = try system.create_vm();
        errdefer vm.deinit();

        try vm.restore_irqchip(state.irqchip);
        try vm.restore_pit(state.pit);

        var mem = try memory.GuestMemory.new(alloc);
        errdefer mem.deinit(alloc);

        const mem_layout = layout.memory_layout(state.ram_size);
        try Self.setup_memory(mem, &mem_layout, alloc);

        // Map regions into kvm
        for (mem.get_regions()) |reg| {
            try vm.set_user_memory_region(reg.gpa, reg.slot, reg.raw);
        }

        return .{
            .device_bus = try DeviceBus.from_snapshot(&state.device_bus, alloc, io),
            .ram_size = state.ram_size,
            .irqs = state.irq_alloc,
            .mmio_alloc = state.mmio_alloc,
            .memory = mem,
            .vm = vm,
        };
    }

    pub const ArchVmState = struct {
        ram_size: usize,
        mmio_alloc: MmioAlloc,
        irq_alloc: IrqAllocator,
        device_bus: DeviceBus.State,
        pit: kvm.Vm.PitState,
        irqchip: kvm.Vm.IrqState,

        pub fn deinit(self: *ArchVmState, alloc: std.mem.Allocator) void {
            self.device_bus.deinit(alloc);
        }
    };

    pub fn snapshot(self: *Self, vm: *Vm, alloc: std.mem.Allocator, io: std.Io) !ArchVmState {
        var bus = try self.device_bus.snapshot(alloc, io);
        errdefer bus.deinit(alloc);

        return .{
            .ram_size = self.ram_size,
            .mmio_alloc = self.mmio_alloc,
            .irq_alloc = self.irqs,
            .device_bus = bus,
            .pit = try vm.archvm.vm.snapshot_pit(),
            .irqchip = try vm.archvm.vm.snapshot_irqchip(),
        };
    }

    pub fn attach_console(
        self: *Self,
        console: *const VmConsoleConfig,
        vm: *Vm,
        state: ?*const ArchVmState,
        alloc: std.mem.Allocator,
    ) !void {
        const bus_state = if (state) |snapshot_state| &snapshot_state.device_bus else null;

        return self.device_bus.attach_console(console, vm, bus_state, alloc);
    }

    pub fn setup_devices(
        self: *Self,
        config: *const VmConfig,
        vm: *Vm,
        alloc: std.mem.Allocator,
        io: std.Io,
    ) !void {
        return self.device_bus.setup_devices(
            &config.device_config,
            &self.mmio_alloc,
            vm,
            &self.irqs,
            alloc,
            io,
        );
    }

    pub fn vm_prerun(
        self: *Self,
        vm: *Vm,
        user_cmdline: []const u8,
        alloc: Allocator,
    ) !void {
        var cmd_line = try std.fmt.allocPrint(alloc, "{s}", .{if (user_cmdline.len != 0)
            user_cmdline
        else
            DEFAULT_CMD_LINE});

        if (self.device_bus.io_bus.pci_bus_obj == null) {
            const old_line = cmd_line;

            cmd_line = try std.fmt.allocPrint(alloc, "{s} pci=off", .{old_line});
            alloc.free(old_line);
        }

        defer alloc.free(cmd_line);

        for (self.device_bus.mmio_bus.virtio_devs.items) |dev| {
            const new_cmd_line = try std.fmt.allocPrint(
                alloc,
                "{s} virtio_mmio.device=4K@0x{x}:{d}",
                .{ cmd_line, dev.base(), dev.irq() },
            );

            alloc.free(cmd_line);
            cmd_line = new_cmd_line;
        }

        try vm.archvm.memory.write(layout.BOOT_CMDLINE_ADDR, cmd_line);
        try acpi.setup_tables(vm);
    }

    fn setup_pagetables(mem: *GuestMemory) !void {
        try mem.write(layout.PGD_ADDR, std.mem.asBytes(&paging.PGD));
        try mem.write(layout.PUD_ADDR, std.mem.asBytes(&paging.PUD));
        try mem.write(layout.PMD_ADDR, std.mem.asBytes(&paging.PMD));
        try mem.write(layout.GDT_ADDR, std.mem.asBytes(&gdt.gdt()));
    }

    fn setup_memory(
        mem: *GuestMemory,
        mem_layout: *const layout.MemoryLayout,
        alloc: Allocator,
    ) !void {
        for (mem_layout.layout) |entry| {
            if (entry.kind == .Ram or entry.kind == .Acpi) {
                const ram = try mmap.mmap(
                    null,
                    entry.length,
                    .{ .READ = true, .WRITE = true },
                    .{ .ANONYMOUS = true, .TYPE = .PRIVATE },
                    -1,
                    0,
                );

                try mem.add(entry.start, ram, true, alloc);
            }
        }
    }

    pub fn deinit(self: *Self, alloc: Allocator, io: std.Io) void {
        self.device_bus.deinit(alloc, io);
    }
};
