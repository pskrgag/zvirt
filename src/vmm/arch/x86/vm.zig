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

pub const DeviceBus = @import("device_bus.zig");
pub const layout = @import("layout.zig");
const DEFAULT_CMD_LINE: []const u8 = "console=ttyS0 earlycon=uart,io,0x3f8 nokaslr pci=off panic=-1 reboot=t";

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

pub fn setup_vcpu(vcpu: *kvm.Vcpu, ep: u64) !void {
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

    const Self = @This();

    pub fn new(alloc: Allocator) !Self {
        var idalloc = IrqAllocator{};

        // Reserve IRQ for com1
        _ = idalloc.allocate_specific(4).?;

        // Reserve IRQ for com2
        _ = idalloc.allocate_specific(3).?;

        // Reserve IRQ for PIT
        _ = idalloc.allocate_specific(0).?;

        // Reserve IRQ for PIC cascade
        _ = idalloc.allocate_specific(2).?;

        return .{ .device_bus = try DeviceBus.new(alloc), .irqs = idalloc };
    }

    pub fn setup_vm(
        self: *Self,
        vm: *kvm.Vm,
        memory: *GuestMemory,
        config: *const VmConfig,
        alloc: Allocator,
    ) !void {
        _ = self;

        try vm.create_pit();
        try Self.setup_memory(memory, config, alloc);
    }

    pub fn attach_console(self: *Self, console: *const VmConsoleConfig, vm: *Vm) !void {
        return self.device_bus.attach_console(console, vm);
    }

    pub fn setup_devices(
        self: *Self,
        config: *const VmConfig,
        vm: *Vm,
        alloc: std.mem.Allocator,
        io: std.Io,
    ) !void {
        return self.device_bus.setup_devices(config, vm, &self.irqs, alloc, io);
    }

    pub fn vm_prerun(
        self: *Self,
        memory: *GuestMemory,
        user_cmdline: []const u8,
        alloc: Allocator,
    ) !void {
        var cmd_line = try std.fmt.allocPrint(alloc, "{s}", .{if (user_cmdline.len != 0)
            user_cmdline
        else
            DEFAULT_CMD_LINE});
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

        try memory.write(layout.BOOT_CMDLINE_ADDR, cmd_line);
    }

    fn setup_memory(memory: *GuestMemory, config: *const VmConfig, alloc: Allocator) !void {
        for (layout.memory_layout(config)) |entry| {
            if (entry.kind == .Ram) {
                const ram = try mmap.mmap(
                    null,
                    entry.length,
                    .{ .READ = true, .WRITE = true },
                    .{ .ANONYMOUS = true, .TYPE = .PRIVATE },
                    -1,
                    0,
                );

                try memory.add(entry.start, ram, true, alloc);
            }
        }

        try memory.write(layout.PGD_ADDR, std.mem.asBytes(&paging.PGD));
        try memory.write(layout.PUD_ADDR, std.mem.asBytes(&paging.PUD));
        try memory.write(layout.PMD_ADDR, std.mem.asBytes(&paging.PMD));
        try memory.write(layout.GDT_ADDR, std.mem.asBytes(&gdt.gdt()));
    }

    pub fn deinit(self: *Self, alloc: Allocator, io: std.Io) void {
        self.device_bus.deinit(alloc, io);
    }
};
