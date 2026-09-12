//! PCI port implementation

const std = @import("std");
const log = std.log.scoped(.pci);
const VirtioPciDevice = @import("../virtio/pci.zig").VirtioPciDevice;
pub const PciBridge = @import("bridge.zig").PciBridge;

const MAX_DEVICES = 32;

pub const PciAddress = struct {
    bus: u8,
    function: u3,
    device: u5,
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
            inline else => |*device| try device.get_config().write_slice(offset, data),
        };
    }
};

pub const PciBus = struct {
    devices: [MAX_DEVICES]?PciDevice,

    const Self = @This();

    pub fn new(bridge: PciBridge) Self {
        var devs: [MAX_DEVICES]?PciDevice = @splat(null);

        devs[0] = PciDevice{ .Brigde = bridge };
        return .{ .devices = devs };
    }

    // Thread unsafe (yet?)
    pub fn attach(self: *Self, dev: PciDevice, id: usize) !void {
        if (self.devices[id] != null)
            return error.DeviceAlreadyExists;

        self.devices[id] = dev;
    }

    pub fn device(self: *Self, id: u32) ?*PciDevice {
        if (self.devices[id]) |*dev| {
            return dev;
        } else {
            return null;
        }
    }
};
