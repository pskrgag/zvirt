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
const VirtQueue = @import("queue.zig").VirtQueue;

const log = std.log.scoped(.virtio_pci);

const VENDOR_ID = 0x1AF4;

fn check_cfg_access(offset: usize, size: usize) !void {
    const T = c.virtio_pci_common_cfg;

    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (offset == @offsetOf(T, field.name) and
            size == @sizeOf(field.type))
        {
            return;
        }
    }

    return error.InvalidAccess;
}

fn set_low(value: *u64, low: u32) void {
    value.* = (value.* & 0xffff_ffff_0000_0000) | @as(u64, low);
}

fn set_high(value: *u64, high: u32) void {
    value.* = (value.* & 0x0000_0000_ffff_ffff) |
        (@as(u64, high) << 32);
}

fn VirtioPci(comptime Device: type) type {
    return struct {
        device: VirtioCore(Device),
        pci: PciDeviceCore,
        allocator: std.mem.Allocator,
        mutex: std.Io.Mutex = .init,
        device_sel: u1 = 0,
        driver_sel: u1 = 0,
        change_vector: u32 = c.VIRTIO_MSI_NO_VECTOR,
        queue_select: u16 = 0,
        queue_vectors: [virtio.MAX_QUEUES_SUPPORTED]u32 = @splat(c.VIRTIO_MSI_NO_VECTOR),
        vm: *Vm,

        const Self = @This();

        pub fn new(device: VirtioCore(Device), bus: *PciBus, vm: *Vm, alloc: std.mem.Allocator) !*Self {
            const self = try alloc.create(Self);
            errdefer alloc.destroy(self);

            var pci = PciDeviceCore.new_device(
                VENDOR_ID,
                Device.PCI_DEVICE_ID,
                Device.PCI_CLASS,
                Device.PCI_SUBCLASS,
                bus,
            );

            try pci.init_msix(2, alloc);

            const bar: u8 = try pci.allocate_bar(.{
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
                .vm = vm,
            };

            return self;
        }

        pub fn deinit(self: *Self, alloc: std.mem.Allocator, io: std.Io) void {
            const allocator = self.allocator;

            self.pci.deinit(alloc);
            self.device.deinit(io);
            allocator.destroy(self);
        }

        fn set_queue_ready(self: *Self, val: u32) !void {
            if (self.active_queue()) |q|
                try q.ready(self.vm.memory, val);
        }

        fn set_queue_num(self: *Self, val: u32) void {
            if (self.active_queue()) |q|
                try q.set_elements(val);
        }

        fn set_queue_desc_low(self: *Self, val: u32) void {
            if (self.active_queue()) |q|
                set_low(&q.desc_ring, val);
        }

        fn set_queue_desc_high(self: *Self, val: u32) void {
            if (self.active_queue()) |q|
                set_high(&q.desc_ring, val);
        }

        fn set_queue_avail_low(self: *Self, val: u32) void {
            if (self.active_queue()) |q|
                set_low(&q.available_ring, val);
        }

        fn set_queue_avail_high(self: *Self, val: u32) void {
            if (self.active_queue()) |q|
                set_high(&q.available_ring, val);
        }

        fn set_queue_used_low(self: *Self, val: u32) void {
            if (self.active_queue()) |q|
                set_low(&q.used_ring, val);
        }

        fn set_queue_used_high(self: *Self, val: u32) void {
            if (self.active_queue()) |q|
                set_high(&q.used_ring, val);
        }

        fn active_queue(self: *Self) ?*VirtQueue {
            return self.device.queue(self.queue_select);
        }

        fn handle_generic_cap_write(self: *Self, offset: usize, data: []const u8) !void {
            try check_cfg_access(offset, data.len);

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
                @offsetOf(c.virtio_pci_common_cfg, "msix_config") => {
                    try self.pci.unmask_irq(value);
                    self.change_vector = value;
                },
                @offsetOf(c.virtio_pci_common_cfg, "queue_select") => self.queue_select = @truncate(value),
                @offsetOf(c.virtio_pci_common_cfg, "queue_size") => {
                    if (self.active_queue()) |queue|
                        try queue.set_elements(value);
                },
                @offsetOf(c.virtio_pci_common_cfg, "queue_avail_lo") => self.set_queue_avail_low(value),
                @offsetOf(c.virtio_pci_common_cfg, "queue_avail_hi") => self.set_queue_avail_high(value),
                @offsetOf(c.virtio_pci_common_cfg, "queue_desc_lo") => self.set_queue_desc_low(value),
                @offsetOf(c.virtio_pci_common_cfg, "queue_desc_hi") => self.set_queue_desc_high(value),
                @offsetOf(c.virtio_pci_common_cfg, "queue_used_lo") => self.set_queue_used_low(value),
                @offsetOf(c.virtio_pci_common_cfg, "queue_used_hi") => self.set_queue_used_high(value),
                @offsetOf(c.virtio_pci_common_cfg, "queue_enable") => {
                    if (self.active_queue()) |queue|
                        try queue.ready(self.vm.memory, value);
                },
                @offsetOf(c.virtio_pci_common_cfg, "queue_msix_vector") => {
                    if (self.queue_select < self.queue_vectors.len)
                        self.queue_vectors[self.queue_select] = value;
                },
                else => @panic("todo generic"),
            }
        }

        fn handle_generic_cap_read(self: *Self, offset: usize, size: usize) !u32 {
            try check_cfg_access(offset, size);

            return switch (offset) {
                @offsetOf(c.virtio_pci_common_cfg, "device_status") => self.device.status,
                @offsetOf(c.virtio_pci_common_cfg, "device_feature") => if (self.device_sel != 0)
                    @truncate(self.device.device_features >> 32)
                else
                    @truncate(self.device.device_features),
                @offsetOf(c.virtio_pci_common_cfg, "msix_config") => self.change_vector,
                @offsetOf(c.virtio_pci_common_cfg, "num_queues") => @truncate(self.device.max_queues()),
                @offsetOf(c.virtio_pci_common_cfg, "config_generation") => 0,

                // TODO: use one region for all queues (for now)
                @offsetOf(c.virtio_pci_common_cfg, "queue_notify_off") => 0,
                @offsetOf(c.virtio_pci_common_cfg, "queue_size") => blk: {
                    const queue = self.active_queue() orelse break :blk 0;

                    break :blk queue.elements;
                },
                @offsetOf(c.virtio_pci_common_cfg, "queue_enable") => blk: {
                    const queue = self.active_queue() orelse break :blk 0;

                    break :blk queue.is_ready;
                },
                @offsetOf(c.virtio_pci_common_cfg, "queue_msix_vector") => blk: {
                    if (self.queue_select < self.queue_vectors.len)
                        break :blk self.queue_vectors[self.queue_select];

                    break :blk 0;
                },
                else => @panic("todo generic"),
            };
        }

        fn signal_queue(self: *Self, idx: usize) !void {
            const vector = self.queue_vectors[idx];
            if (vector != c.VIRTIO_MSI_NO_VECTOR)
                try self.pci.signal_vector(self.vm, vector);
        }

        pub fn register_events(self: *Self, vm: *Vm, id: u29) !void {
            if (self.device.event_source()) |event|
                try vm.register_fd(event, id, .pci);
        }

        pub fn handle_event(self: *Self, fd: std.posix.fd_t, io: std.Io) !void {
            if (fd != self.device.event_source())
                return error.UnknownPciEvent;

            try self.mutex.lock(io);
            defer self.mutex.unlock(io);

            // VirtioCore currently publishes async completions to queue 0.
            if (try self.device.handle_completion_event())
                try self.signal_queue(0);
        }

        fn handle_notification_write(self: *Self, offset: usize, data: []const u8, io: std.Io) !void {
            std.debug.assert(offset == 0);

            if (data.len != 2)
                return;

            const queue = std.mem.readInt(u16, data[0..2], .little);
            const irq = try self.device.notify_queue(queue, self.vm, io);

            if (irq) {
                log.debug("Signaling MSIx for queue {}\n", .{queue});
                try self.signal_queue(queue);
            }
        }

        fn mmio_read(_self: *anyopaque, offset: usize, data: []u8, io: std.Io) !void {
            const self: *Self = @ptrCast(@alignCast(_self));
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);

            log.debug("read from 0x{x}, data {x}\n", .{ offset, data });

            const res = if (offset < 128)
                try self.handle_generic_cap_read(offset, data.len)
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
            const self: *Self = @ptrCast(@alignCast(_self));
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);
            log.debug("write from 0x{x}, data {x}\n", .{ offset, data });

            if (offset < 128) {
                try self.handle_generic_cap_write(offset, data);
            } else if (offset >= 256 and offset < 356) {
                try self.handle_notification_write(offset - 256, data, io);
            }
        }
    };
}

pub const VirtioPciDevice = union(enum) {
    block: *VirtioPci(Block),

    const Self = @This();

    pub fn register_events(self: *Self, vm: *Vm, id: u29) !void {
        switch (self.*) {
            inline else => |device| try device.register_events(vm, id),
        }
    }

    pub fn handle_event(self: *Self, fd: std.posix.fd_t, io: std.Io) !void {
        switch (self.*) {
            inline else => |device| try device.handle_event(fd, io),
        }
    }

    pub fn new(
        kind: VirtioDeviceInit,
        bus: *PciBus,
        vm: *Vm,
        alloc: std.mem.Allocator,
        io: std.Io,
    ) !Self {
        return switch (kind) {
            .BlockDevice => |block| blk: {
                var device = VirtioCore(Block).new(try Block.new(block.path, block.async, io), alloc);
                errdefer device.deinit(io);

                break :blk .{ .block = try VirtioPci(Block).new(device, bus, vm, alloc) };
            },
        };
    }

    pub fn pci_core(self: *Self) *PciDeviceCore {
        return switch (self.*) {
            inline else => |device| &device.pci,
        };
    }

    pub fn deinit(self: *Self, alloc: std.mem.Allocator, io: std.Io) void {
        switch (self.*) {
            inline else => |device| device.deinit(alloc, io),
        }
    }
};
