//! x86 machine setup policy.

const std = @import("std");
const kvm = @import("kvm");
const GuestMemory = @import("../../memory.zig").GuestMemory;
const VmConfig = @import("../../root.zig").VmConfig;
const VmConsoleConfig = @import("../../root.zig").VmConsoleConfig;
const Vm = @import("../../root.zig").Vm;
const posix = std.posix;
const Allocator = std.mem.Allocator;
const gdt = @import("gdt.zig");
const paging = @import("paging.zig");
const IoResult = @import("kvm").IoResult;

pub const layout = @import("layout.zig");

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

pub const io_bus = @import("io_bus.zig");
pub const mmio_bus = @import("mmio_bus.zig");

pub const Config = struct {};

pub const DeviceBus = struct {
    io_bus: io_bus = .{},
    mmio_bus: mmio_bus = .{},

    const Self = @This();

    pub fn attach_console(self: *Self, console: *const VmConsoleConfig, vm: *Vm) !void {
        try self.io_bus.attach_console(console, vm);
    }

    pub fn deinit(self: *Self) void {
        self.io_bus.deinit();
    }

    pub fn handle_event(self: *Self, id: u29, vm: *Vm, io: std.Io) !void {
        try self.io_bus.handle_event(id, vm, io);
    }

    pub fn handle_io(self: *Self, io_request: anytype, vm: *Vm, io: std.Io) !bool {
        return self.io_bus.handle_io(io_request, vm, io);
    }

    pub fn handle_mmio(self: *Self, mmio_request: anytype, io: std.Io) !?IoResult {
        return self.mmio_bus.handle_mmio(mmio_request, io);
    }
};

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

pub fn setup_vm(vm: *kvm.Vm) !void {
    try vm.create_pit();
}

pub fn setup_memory(memory: *GuestMemory, config: *const VmConfig, alloc: Allocator) !void {
    for (layout.memory_layout(config)) |entry| {
        if (entry.kind == .Ram) {
            const ram = try posix.mmap(
                null,
                entry.length,
                .{ .READ = true, .WRITE = true },
                .{ .ANONYMOUS = true, .TYPE = .PRIVATE },
                -1,
                0,
            );

            try memory.add(entry.start, ram, alloc);
        }
    }

    try memory.write(layout.PGD_ADDR, std.mem.asBytes(&paging.PGD));
    try memory.write(layout.PUD_ADDR, std.mem.asBytes(&paging.PUD));
    try memory.write(layout.PMD_ADDR, std.mem.asBytes(&paging.PMD));
    try memory.write(layout.GDT_ADDR, std.mem.asBytes(&gdt.gdt()));
}
