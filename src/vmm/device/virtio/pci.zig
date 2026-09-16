//! PCI virtio device

const std = @import("std");
const virtio = @import("root.zig");
const VirtioCore = virtio.VirtioCore;
const VirtioDeviceInit = virtio.VirtioDeviceInit;
const pci_config = @import("../pci/config.zig");
const PciConfigSpace = pci_config.PciConfigSpace;
const Bar = @import("../pci/bar.zig").Bar;
const BarAllocator = @import("../pci/bar.zig").BarAllocator;
const Block = @import("block.zig").Block;
const Vm = @import("../../root.zig").Vm;
pub const c = @cImport({
    @cInclude("linux/virtio_pci.h");
});
const BarMmio = @import("../pci/root.zig").BarMmio;
const PciDeviceCore = @import("../pci/root.zig").PciDeviceCore;
const PciBus = @import("../pci/root.zig").PciBus;

const log = std.log.scoped(.virtio_pci);

const VENDOR_ID = 0x1AF4;

fn VirtioPci(comptime Device: type) type {
    return struct {
        device: VirtioCore(Device),
        pci: PciDeviceCore,
        allocator: std.mem.Allocator,
        device_sel: u1 = 0,
        driver_sel: u1 = 0,

        const Self = @This();

        pub fn new(device: VirtioCore(Device), bus: *PciBus, alloc: std.mem.Allocator) !*Self {
            const self = try alloc.create(Self);
            errdefer alloc.destroy(self);

            var pci = PciDeviceCore.new_device(
                VENDOR_ID,
                Device.PCI_DEVICE_ID,
                Device.PCI_CLASS,
                Device.PCI_SUBCLASS,
                bus,
            );

            const bar: u8 = try pci.allocate_bar(bus, .{
                .context = self,
                .read_fn = mmio_read,
                .write_fn = mmio_write,
            });

            // Generic cap
            const gen_cap = c.virtio_pci_cap{
                .cap_vndr = 0x09,
                .cap_next = 0,
                .cap_len = @sizeOf(c.virtio_pci_cap),
                .cfg_type = c.VIRTIO_PCI_CAP_COMMON_CFG,
                .bar = bar,
                .id = 0,
                .padding = @splat(0),
                .offset = 0,
                .length = @sizeOf(c.virtio_pci_common_cfg),
            };

            const isr_cap = c.virtio_pci_cap{
                .cap_vndr = 0x09,
                .cap_next = 0,
                .cap_len = @sizeOf(c.virtio_pci_cap),
                .cfg_type = c.VIRTIO_PCI_CAP_ISR_CFG,
                .bar = bar,
                .id = 0,
                .padding = @splat(0),
                .offset = 128,
                .length = 2,
            };

            const notify_cap = c.virtio_pci_notify_cap{
                .cap = .{
                    .cap_vndr = 0x09,
                    .cap_next = 0,
                    .cap_len = @sizeOf(c.virtio_pci_notify_cap),
                    .cfg_type = c.VIRTIO_PCI_CAP_NOTIFY_CFG,
                    .bar = bar,
                    .id = 0,
                    .padding = @splat(0),
                    .offset = 256,
                    .length = 4,
                },
                .notify_off_multiplier = 0,
            };

            const device_conifg = c.virtio_pci_notify_cap{
                .cap = .{
                    .cap_vndr = 0x09,
                    .cap_next = 0,
                    .cap_len = @sizeOf(c.virtio_pci_notify_cap),
                    .cfg_type = c.VIRTIO_PCI_CAP_DEVICE_CFG,
                    .bar = bar,
                    .id = 0,
                    .padding = @splat(0),
                    .offset = 384,
                    .length = @sizeOf(@TypeOf(device.device.config)),
                },
                .notify_off_multiplier = 0,
            };

            try pci.config.add_capability(std.mem.asBytes(&gen_cap));
            try pci.config.add_capability(std.mem.asBytes(&isr_cap));
            try pci.config.add_capability(std.mem.asBytes(&notify_cap));
            try pci.config.add_capability(std.mem.asBytes(&device_conifg));

            self.* = .{
                .device = device,
                .pci = pci,
                .allocator = alloc,
            };

            return self;
        }

        pub fn deinit(self: *Self, io: std.Io) void {
            const allocator = self.allocator;
            self.device.deinit(io);
            allocator.destroy(self);
        }

        fn handle_generic_cap_write(self: *Self, offset: usize, data: []const u8) !void {
            const value: u32 = switch (data.len) {
                @sizeOf(u8) => data[0],
                @sizeOf(u16) => std.mem.readInt(u16, data[0..@sizeOf(u16)], .little),
                @sizeOf(u32) => std.mem.readInt(u32, data[0..@sizeOf(u32)], .little),
                else => unreachable,
            };

            switch (offset) {
                @offsetOf(c.virtio_pci_common_cfg, "device_status") => self.device.status = @truncate(value),
                @offsetOf(c.virtio_pci_common_cfg, "device_feature_select") => self.device_sel = @truncate(value),
                @offsetOf(c.virtio_pci_common_cfg, "guest_feature_select") => self.driver_sel = @truncate(value),
                @offsetOf(c.virtio_pci_common_cfg, "guest_feature") => self.device.update_driver_feats(value, self.driver_sel != 0),
                else => @panic("todo generic"),
            }
        }

        fn handle_generic_cap_read(self: *Self, offset: usize) !u32 {
            return switch (offset) {
                @offsetOf(c.virtio_pci_common_cfg, "device_status") => self.device.status,
                @offsetOf(c.virtio_pci_common_cfg, "device_feature") => if (self.device_sel != 0)
                    @truncate(self.device.device_features >> 32)
                else
                    @truncate(self.device.device_features),
                else => @panic("todo generic"),
            };
        }

        fn mmio_read(_self: *anyopaque, offset: usize, data: []u8, io: std.Io) !void {
            _ = io;

            const self: *Self = @ptrCast(@alignCast(_self));

            log.debug("read from 0x{x}, data {x}\n", .{ offset, data });

            const res = if (offset < 128)
                try self.handle_generic_cap_read(offset)
            else
                self.device.device.read_config(@truncate(offset - 384));

            switch (data.len) {
                @sizeOf(u8) => data[0] = @truncate(res),
                @sizeOf(u16) => std.mem.writeInt(u16, data[0..@sizeOf(u16)], @truncate(res), .little),
                @sizeOf(u32) => std.mem.writeInt(u32, data[0..@sizeOf(u32)], res, .little),
                else => unreachable,
            }
        }

        fn mmio_write(_self: *anyopaque, offset: usize, data: []const u8, io: std.Io) !void {
            _ = io;

            const self: *Self = @ptrCast(@alignCast(_self));
            log.debug("write from 0x{x}, data {x}\n", .{ offset, data });

            if (offset < @sizeOf(c.virtio_pci_common_cfg)) {
                try self.handle_generic_cap_write(offset, data);
            } else {
                @panic("todo");
            }
        }
    };
}

pub const VirtioPciDevice = union(enum) {
    block: *VirtioPci(Block),

    const Self = @This();

    pub fn new(
        kind: VirtioDeviceInit,
        bus: *PciBus,
        alloc: std.mem.Allocator,
        io: std.Io,
    ) !Self {
        return switch (kind) {
            .BlockDevice => |path| blk: {
                var device = VirtioCore(Block).new(try Block.new(path, io), alloc);
                errdefer device.deinit(io);

                break :blk .{ .block = try VirtioPci(Block).new(device, bus, alloc) };
            },
        };
    }

    pub fn pci_core(self: *Self) *PciDeviceCore {
        return switch (self.*) {
            inline else => |device| &device.pci,
        };
    }

    pub fn deinit(self: *Self, io: std.Io) void {
        switch (self.*) {
            inline else => |device| device.deinit(io),
        }
    }
};
