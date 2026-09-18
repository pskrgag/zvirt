//! PCI host bridge

const PciConfigSpace = @import("config.zig").PciConfigSpace;
const BarAllocator = @import("bar.zig").BarAllocator;
const BarMmio = @import("root.zig").BarMmio;
const pci_config = @import("config.zig");
const PciDeviceCore = @import("root.zig").PciDeviceCore;

const ZVIRT_VENDOR_ID = 0x1234;
const ZVIRT_BRIDGE_ID = 0x5678;

pub const PciBridge = struct {
    pci: PciDeviceCore,

    const Self = @This();

    pub fn new() Self {
        // TODO: this is bad...
        return .{
            .pci = PciDeviceCore.new_bridge(ZVIRT_VENDOR_ID, ZVIRT_BRIDGE_ID, .Brigde, 0, undefined),
        };
    }

    pub fn pci_core(self: *Self) *PciDeviceCore {
        return &self.pci;
    }
};
