//! PCI host bridge

const PciConfigSpace = @import("config.zig").PciConfigSpace;

const ZVIRT_VENDOR_ID = 0x1234;
const ZVIRT_BRIDGE_ID = 0x5678;

pub const PciBridge = struct {
    config: PciConfigSpace,

    const Self = @This();

    pub fn new() Self {
        return .{ .config = PciConfigSpace.new_type0(ZVIRT_VENDOR_ID, ZVIRT_BRIDGE_ID, .Brigde, 0) };
    }

    pub fn get_config(self: *Self) *PciConfigSpace {
        return &self.config;
    }
};
