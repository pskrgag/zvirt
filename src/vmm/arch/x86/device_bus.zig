//! DeviceBus for x86

const std = @import("std");
const VmConsoleConfig = @import("../../root.zig").VmConsoleConfig;
const VmConfig = @import("../../root.zig").VmConfig;
const IoResult = @import("kvm").IoResult;
const Vm = @import("../../root.zig").Vm;
const VirtioMmioDevice = @import("../../device/virtio/mmio.zig").VirtioMmioDevice;
const VirtioPciDevice = @import("../../device/virtio/pci.zig").VirtioPciDevice;
const PciDevice = @import("../../device/pci/root.zig").PciDevice;
const layout = @import("layout.zig");
const IrqAllocator = @import("vm.zig").IrqAllocator;
const EventSource = @import("../../root.zig").EventSource;

const io_bus_struct = @import("io_bus.zig");
const mmio_bus_struct = @import("mmio_bus.zig");

io_bus: io_bus_struct,
mmio_bus: *mmio_bus_struct,

const Self = @This();

pub fn attach_console(self: *Self, console: *const VmConsoleConfig, vm: *Vm) !void {
    try self.io_bus.attach_console(console, vm);
}

pub fn deinit(self: *Self, alloc: std.mem.Allocator, io: std.Io) void {
    self.mmio_bus.deinit(alloc, io);
    self.io_bus.deinit(alloc, io);
}

pub fn handle_event(
    self: *Self,
    source: EventSource,
    id: u29,
    fd: std.posix.fd_t,
    io: std.Io,
) !void {
    switch (source) {
        .io_bus => try self.io_bus.handle_event(id, io),
        .virtio => try self.mmio_bus.handle_event(id, fd, io),
        .pci => {
            const bus = self.io_bus.pci_bus() orelse return error.UnknownPciDevice;
            if (id >= bus.devices.len) return error.UnknownPciDevice;
            const dev = bus.device(id) orelse return error.UnknownPciDevice;
            try dev.handle_event(fd, io);
        },
        else => unreachable,
    }
}

pub fn handle_io(self: *Self, io_request: anytype, io: std.Io) !bool {
    return self.io_bus.handle_io(io_request, io);
}

pub fn handle_mmio(self: *Self, mmio_request: anytype, io: std.Io) !?IoResult {
    return self.mmio_bus.handle_mmio(mmio_request, io);
}

pub fn new(config: *const VmConfig, alloc: std.mem.Allocator) !Self {
    return .{
        .mmio_bus = try mmio_bus_struct.new(alloc),
        .io_bus = io_bus_struct.new(config),
    };
}

pub fn setup_devices(
    self: *Self,
    config: *const VmConfig,
    vm: *Vm,
    irq_alloc: *IrqAllocator,
    alloc: std.mem.Allocator,
    io: std.Io,
) !void {
    if (config.block_device.path.len != 0) {
        const base = layout.virtio_device(config, 0);
        const irq = irq_alloc.allocate() orelse return error.CannotAllocateIrq;

        errdefer irq_alloc.free(irq);

        if (!config.pci) {
            var dev = try VirtioMmioDevice.new(
                base,
                .{ .BlockDevice = .{
                    .path = config.block_device.path,
                    .async = config.block_device.async,
                } },
                vm,
                @truncate(irq),
                alloc,
                io,
            );
            errdefer dev.deinit(io);

            try self.mmio_bus.register_device(vm, dev);
        } else {
            var dev = try VirtioPciDevice.new(
                .{ .BlockDevice = .{
                    .path = config.block_device.path,
                    .async = config.block_device.async,
                } },
                self.io_bus.pci_bus().?,
                vm,
                alloc,
                io,
            );
            const pci_dev = self.io_bus.attach_pci_device(PciDevice{ .Virtio = dev }, 1) catch |err| {
                dev.deinit(alloc, io);
                return err;
            };
            const bars = pci_dev.num_bars();

            for (0..bars) |i| {
                if (pci_dev.bar_mmio(i)) |bar|
                    try self.mmio_bus.register_range(bar.base, bar.size, bar.dev);
            }
            try pci_dev.register_events(vm, 1);
        }
    }
}
