//! PCI host bridge

const PciConfigSpace = @import("config.zig").PciConfigSpace;
const BarAllocator = @import("bar.zig").BarAllocator;
const BarMmio = @import("root.zig").BarMmio;
const pci_config = @import("config.zig");
const PciDeviceCore = @import("root.zig").PciDeviceCore;
const PciBus = @import("root.zig").PciBus;
const Vm = @import("../../root.zig").Vm;

const ZVIRT_VENDOR_ID = 0x1234;
const ZVIRT_BRIDGE_ID = 0x5678;

pub const PciBridge = struct {
    pci: PciDeviceCore,

    const Self = @This();

    pub const State = struct {
        pci: PciDeviceCore.State,
    };

    pub fn new() Self {
        // TODO: this is bad...
        return .{
            .pci = PciDeviceCore.new_bridge(
                ZVIRT_VENDOR_ID,
                ZVIRT_BRIDGE_ID,
                .Brigde,
                0,
                undefined,
            ),
        };
    }

    pub fn from_snapshot(state: *const State, bus: *PciBus, vm: *Vm) !Self {
        if (state.pci.active_bars != 0 or state.pci.msix != null) {
            return error.InvalidSnapshot;
        }
        return .{ .pci = .{ .config = state.pci.config, .bus = bus, .vm = vm } };
    }

    pub fn snapshot(self: *const Self) State {
        return .{ .pci = self.pci.snapshot() };
    }

    pub fn pci_core(self: *Self) *PciDeviceCore {
        return &self.pci;
    }
};
