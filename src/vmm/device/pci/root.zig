//! PCI port implementation

const std = @import("std");
const log = std.log.scoped(.pci);
const VirtioPciDevice = @import("../virtio/pci.zig").VirtioPciDevice;
const arch = @import("../../arch/root.zig");
const VmConfig = @import("../../root.zig").VmConfig;
pub const Bar = @import("bar.zig").Bar;
pub const BarAllocator = @import("bar.zig").BarAllocator;
const MmioDevice = @import("../root.zig").MmioDevice;

pub const PciBridge = @import("bridge.zig").PciBridge;
const MAX_DEVICES = 32;

pub const PciAddress = struct {
    bus: u8,
    function: u3,
    device: u5,
};

pub const BarMmio = struct {
    base: u64,
    size: usize,
    dev: MmioDevice,
};

pub const PciDevice = union(enum) {
    Brigde: PciBridge,
    Virtio: VirtioPciDevice,

    const Self = @This();

    pub fn read_config(self: *Self, offset: u8) !u32 {
        return switch (self.*) {
            inline else => |*device| device.get_config().read(u32, offset),
        };
    }

    pub fn write_config(self: *Self, offset: u8, data: []const u8) !void {
        return switch (self.*) {
            inline else => |*device| try device.write_config(offset, data),
        };
    }

    pub fn allocate_bars(self: *Self, alloc: *BarAllocator) !void {
        return switch (self.*) {
            inline else => |*device| try device.allocate_bars(alloc),
        };
    }

    pub fn bar_mmio(self: *Self, idx: usize) ?BarMmio {
        return switch (self.*) {
            inline else => |*device| device.bar_mmio(idx),
        };
    }

    pub fn num_bars(self: *const Self) usize {
        return switch (self.*) {
            inline else => |*device| device.num_bars(),
        };
    }
};

pub const PciBus = struct {
    devices: [MAX_DEVICES]?PciDevice,
    allocator: BarAllocator,

    const Self = @This();

    pub fn new(bridge: PciBridge, config: *const VmConfig) Self {
        var devs: [MAX_DEVICES]?PciDevice = @splat(null);
        const pci_range = arch.layout.pci_range(config);
        const allocator = BarAllocator.new(pci_range.start, pci_range.length);

        devs[0] = PciDevice{ .Brigde = bridge };
        return .{ .devices = devs, .allocator = allocator };
    }

    // Thread unsafe (yet?)
    pub fn attach(self: *Self, _dev: PciDevice, id: usize) !*PciDevice {
        var dev = _dev;
        if (self.devices[id] != null)
            return error.DeviceAlreadyExists;

        try dev.allocate_bars(&self.allocator);
        self.devices[id] = dev;
        return &(self.devices[id].?);
    }

    pub fn device(self: *Self, id: u32) ?*PciDevice {
        if (self.devices[id]) |*dev| {
            return dev;
        } else {
            return null;
        }
    }
};
