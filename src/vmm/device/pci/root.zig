//! PCI port implementation

const std = @import("std");
const log = std.log.scoped(.pci);
const VirtioPciDevice = @import("../virtio/pci.zig").VirtioPciDevice;
const arch = @import("../../arch/root.zig");
const VmConfig = @import("../../root.zig").VmConfig;
pub const Bar = @import("bar.zig").Bar;
pub const BarAllocator = @import("bar.zig").BarAllocator;
const MmioDevice = @import("../root.zig").MmioDevice;
const PciConfigSpace = @import("config.zig").PciConfigSpace;
const PciClass = @import("config.zig").PciClass;
const msix = @import("msix.zig");
const Vm = @import("../../root.zig").Vm;

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

pub const PciDeviceCore = struct {
    config: PciConfigSpace,
    bars: [6]?Bar = @splat(null),
    active_bars: u8 = 0,
    msix: ?*msix.Msix = null,
    bus: *PciBus,
    mutex: std.Io.Mutex = .init,

    const Self = @This();

    pub fn new_device(vendor_id: u16, device_id: u16, class: PciClass, subclass: u8, bus: *PciBus) Self {
        const config = PciConfigSpace.new_type0(
            vendor_id,
            device_id,
            class,
            subclass,
        );

        return .{
            .config = config,
            .bus = bus,
        };
    }

    pub fn new_bridge(vendor_id: u16, device_id: u16, class: PciClass, subclass: u8, bus: *PciBus) Self {
        const config = PciConfigSpace.new_type0(
            vendor_id,
            device_id,
            class,
            subclass,
        );

        return .{
            .config = config,
            .bus = bus,
        };
    }

    // Thread unsafe
    pub fn init_msix(self: *Self, irqs: usize, alloc: std.mem.Allocator) !void {
        self.msix = try msix.Msix.new(self, irqs, alloc);
    }

    pub fn signal_vector(self: *Self, vm: *Vm, vector: usize, io: std.Io) !void {
        try self.msix.?.signal(self, vector, vm, io);
    }

    // Thread unsafe
    pub fn allocate_bar(self: *Self, handler: MmioDevice) !u8 {
        if (self.active_bars == self.bars.len)
            return error.NoMoreBars;

        const bar_idx = self.active_bars;
        const bar = try self.bus.allocator.allocate(4096, handler);
        try self.config.set_bar(@truncate(bar_idx), bar.value());

        std.debug.assert(self.bars[bar_idx] == null);
        self.bars[bar_idx] = bar;

        self.active_bars += 1;
        return bar_idx;
    }

    pub fn write_config(self: *Self, offset: u8, data: []const u8, io: std.Io) !void {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);

        // Handle BAR writes
        if (offset >= 0x10 and offset < 0x28) {
            std.debug.assert(offset % 4 == 0);
            std.debug.assert(data.len == 4);

            const bar = (offset - 0x10) / 4;

            if (bar < self.bars.len) {
                if (self.bars[bar]) |b| {
                    if (std.mem.eql(u8, data[0..4], &.{ 0xff, 0xff, 0xff, 0xff })) {
                        try self.config.set_bar(@truncate(bar), @truncate(~(b.size - 1)));
                    } else {
                        try self.config.set_bar(@truncate(bar), std.mem.readInt(u32, data[0..4], .little));
                    }

                    return;
                }
            }
        }

        try self.config.write_slice(offset, data);
    }

    pub fn read_config(self: *Self, T: type, offset: u8, io: std.Io) !T {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);

        return try self.config.read(T, offset);
    }

    // Thread unsafe
    pub fn bar_mmio(self: *Self, idx: usize) ?BarMmio {
        if (self.bars[idx]) |bar| {
            return .{
                .base = bar.base,
                .size = bar.size,
                .dev = bar.handler,
            };
        } else {
            return null;
        }
    }

    pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
        if (self.msix) |m|
            m.deinit(alloc);
    }
};

pub const PciDevice = union(enum) {
    Brigde: PciBridge,
    Virtio: VirtioPciDevice,

    const Self = @This();

    pub fn register_events(self: *Self, vm: *Vm, id: u29) !void {
        switch (self.*) {
            .Brigde => {},
            .Virtio => |*dev| try dev.register_events(vm, id),
        }
    }

    pub fn handle_event(self: *Self, fd: std.posix.fd_t, io: std.Io) !void {
        switch (self.*) {
            .Brigde => return error.UnknownPciEvent,
            .Virtio => |*dev| try dev.handle_event(fd, io),
        }
    }

    pub fn deinit(self: *Self, alloc: std.mem.Allocator, io: std.Io) void {
        switch (self.*) {
            .Brigde => {},
            .Virtio => |*device| device.deinit(alloc, io),
        }
    }

    pub fn read_config(self: *Self, offset: u8, io: std.Io) !u32 {
        return switch (self.*) {
            inline else => |*device| device.pci_core().read_config(u32, offset, io),
        };
    }

    pub fn write_config(self: *Self, offset: u8, data: []const u8, io: std.Io) !void {
        return switch (self.*) {
            inline else => |*device| try device.pci_core().write_config(offset, data, io),
        };
    }

    pub fn num_bars(self: *Self) usize {
        return switch (self.*) {
            inline else => |*device| device.pci_core().active_bars,
        };
    }

    pub fn bar_mmio(self: *Self, idx: usize) ?BarMmio {
        return switch (self.*) {
            inline else => |*device| device.pci_core().bar_mmio(idx),
        };
    }
};

pub const PciBus = struct {
    devices: [MAX_DEVICES]?PciDevice,
    allocator: BarAllocator,

    const Self = @This();

    pub fn new(bridge: PciBridge, config: *const VmConfig, alloc: std.mem.Allocator) !*Self {
        const self = try alloc.create(Self);

        var devs: [MAX_DEVICES]?PciDevice = @splat(null);
        const pci_range = arch.layout.pci_range(config);
        const allocator = BarAllocator.new(pci_range.start, pci_range.length);

        devs[0] = PciDevice{ .Brigde = bridge };
        self.* = .{ .devices = devs, .allocator = allocator };

        return self;
    }

    pub fn deinit(self: *Self, alloc: std.mem.Allocator, io: std.Io) void {
        for (&self.devices) |*slot| {
            if (slot.*) |*dev|
                dev.deinit(alloc, io);

            slot.* = null;
        }

        alloc.destroy(self);
    }

    // Takes ownership on success. Thread unsafe (yet?)
    pub fn attach(self: *Self, dev: PciDevice, id: usize) !*PciDevice {
        if (self.devices[id] != null)
            return error.DeviceAlreadyExists;

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
