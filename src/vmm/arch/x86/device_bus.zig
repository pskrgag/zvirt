//! DeviceBus for x86

const std = @import("std");
const VmConsoleConfig = @import("../../root.zig").VmConsoleConfig;
const VmConfig = @import("../../root.zig").VmConfig;
const IoResult = @import("kvm").IoResult;
const Vm = @import("../../root.zig").Vm;
const VirtioDevice = @import("../../device/root.zig").VirtioDevice;
const layout = @import("layout.zig");
const IrqAllocator = @import("vm.zig").IrqAllocator;

const io_bus_struct = @import("io_bus.zig");
const mmio_bus_struct = @import("mmio_bus.zig");

io_bus: io_bus_struct = .{},
mmio_bus: *mmio_bus_struct,

const Self = @This();

pub fn attach_console(self: *Self, console: *const VmConsoleConfig, vm: *Vm) !void {
    try self.io_bus.attach_console(console, vm);
}

pub fn deinit(self: *Self, alloc: std.mem.Allocator, io: std.Io) void {
    self.mmio_bus.deinit(alloc, io);
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

pub fn new(alloc: std.mem.Allocator) !Self {
    return .{ .mmio_bus = try mmio_bus_struct.new(alloc) };
}

pub fn setup_devices(
    self: *Self,
    config: *const VmConfig,
    vm: *Vm,
    irq_alloc: *IrqAllocator,
    alloc: std.mem.Allocator,
    io: std.Io,
) !void {
    if (config.block_device.len != 0) {
        const base = layout.virtio_device(config, 0);
        const irq = irq_alloc.allocate() orelse return error.CannotAllocateIrq;

        errdefer irq_alloc.free(irq);

        self.mmio_bus.register_device(
            try VirtioDevice.new(
                base,
                .{ .BlockDevice = config.block_device },
                vm,
                @truncate(irq),
                alloc,
                io,
            ),
        );
    }
}
