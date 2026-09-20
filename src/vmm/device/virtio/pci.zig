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
const Atomic = std.atomic.Value;

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

fn VirtioPci(comptime Device: type) type {
    return struct {
        device: VirtioCore(Device),
        pci: PciDeviceCore,
        allocator: std.mem.Allocator,
        state_lock: std.Io.Mutex = .init,
        device_sel: u1 = 0,
        driver_sel: u1 = 0,
        change_vector: u32 = c.VIRTIO_MSI_NO_VECTOR,
        queue_select: u16 = 0,
        queue_vectors: [virtio.MAX_QUEUES_SUPPORTED]Atomic(u32) = @splat(Atomic(u32).init(c.VIRTIO_MSI_NO_VECTOR)),
        vm: *Vm,
        bar: u8,

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

            _ = try pci.config.add_capability(std.mem.asBytes(&gen_cap));
            _ = try pci.config.add_capability(std.mem.asBytes(&isr_cap));
            _ = try pci.config.add_capability(std.mem.asBytes(&notify_cap));
            _ = try pci.config.add_capability(std.mem.asBytes(&device_conifg));

            self.* = .{
                .device = device,
                .pci = pci,
                .allocator = alloc,
                .vm = vm,
                .bar = bar,
            };

            return self;
        }

        pub fn deinit(self: *Self, alloc: std.mem.Allocator, io: std.Io) void {
            const allocator = self.allocator;

            self.pci.deinit(alloc);
            self.device.deinit(io);
            allocator.destroy(self);
        }

        fn handle_generic_cap_write(self: *Self, offset: usize, data: []const u8, io: std.Io) !void {
            try check_cfg_access(offset, data.len);

            try self.state_lock.lock(io);
            defer self.state_lock.unlock(io);

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
                    // try self.pci.unmask_irq(value);
                    self.change_vector = value;
                },
                @offsetOf(c.virtio_pci_common_cfg, "queue_select") => self.queue_select = @truncate(value),
                @offsetOf(c.virtio_pci_common_cfg, "queue_size") => try self.device.set_queue_num(self.queue_select, value, io),
                @offsetOf(c.virtio_pci_common_cfg, "queue_avail_lo") => try self.device.set_queue_avail_low(self.queue_select, value, io),
                @offsetOf(c.virtio_pci_common_cfg, "queue_avail_hi") => try self.device.set_queue_avail_high(self.queue_select, value, io),
                @offsetOf(c.virtio_pci_common_cfg, "queue_desc_lo") => try self.device.set_queue_desc_low(self.queue_select, value, io),
                @offsetOf(c.virtio_pci_common_cfg, "queue_desc_hi") => try self.device.set_queue_desc_high(self.queue_select, value, io),
                @offsetOf(c.virtio_pci_common_cfg, "queue_used_lo") => try self.device.set_queue_used_low(self.queue_select, value, io),
                @offsetOf(c.virtio_pci_common_cfg, "queue_used_hi") => try self.device.set_queue_used_high(self.queue_select, value, io),
                @offsetOf(c.virtio_pci_common_cfg, "queue_enable") => try self.device.set_queue_ready(self.queue_select, self.vm.memory, value, io),
                @offsetOf(c.virtio_pci_common_cfg, "queue_msix_vector") => {
                    if (self.queue_select < self.queue_vectors.len)
                        self.queue_vectors[self.queue_select].store(value, .monotonic);
                },
                else => @panic("todo generic"),
            }
        }

        fn handle_generic_cap_read(self: *Self, offset: usize, size: usize, io: std.Io) !u32 {
            try check_cfg_access(offset, size);

            try self.state_lock.lock(io);
            defer self.state_lock.unlock(io);

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
                @offsetOf(c.virtio_pci_common_cfg, "queue_size") => try self.device.get_queue_num(self.queue_select, io),
                @offsetOf(c.virtio_pci_common_cfg, "queue_enable") => try self.device.get_queue_ready(self.queue_select, io),
                @offsetOf(c.virtio_pci_common_cfg, "queue_msix_vector") => blk: {
                    if (self.queue_select < self.queue_vectors.len)
                        break :blk self.queue_vectors[self.queue_select].load(.monotonic);

                    break :blk 0;
                },
                else => @panic("todo generic"),
            };
        }

        fn signal_queue(self: *Self, idx: usize, io: std.Io) !void {
            const vector = self.queue_vectors[idx].load(.monotonic);

            if (vector != c.VIRTIO_MSI_NO_VECTOR)
                try self.pci.signal_vector(self.vm, vector, io);
        }

        pub fn register_events(self: *Self, vm: *Vm, id: u29) !void {
            if (self.device.event_source()) |event|
                try vm.register_fd(event, id, .pci);

            const bar = self.pci.bars[self.bar].?;

            for (0..self.device.max_queues()) |queue_idx| {
                const notifyfd = self.device.notifyfd_for_queue(queue_idx) catch @panic("should not happen");

                try vm.register_ioevent(
                    notifyfd,
                    bar.base + 256,
                    @sizeOf(u16),
                    queue_idx,
                );

                try vm.register_fd(notifyfd.as_fd(), id, .pci);
            }
        }

        fn handle_completion_event(self: *Self, io: std.Io) !void {
            if (try self.device.handle_completion_event(io))
                try self.signal_queue(0, io);
        }

        pub fn handle_event(self: *Self, fd: std.posix.fd_t, io: std.Io) !void {
            // There only one queue in async mode
            if (fd == self.device.event_source()) {
                try self.handle_completion_event(io);
                return;
            }

            const result = try self.device.handle_notify(fd, self.vm, io);
            if (result.proccessed) {
                try self.signal_queue(result.queue, io);
            }
        }

        fn mmio_read(_self: *anyopaque, offset: usize, data: []u8, io: std.Io) !void {
            const self: *Self = @ptrCast(@alignCast(_self));

            log.debug("read from 0x{x}, data {x}\n", .{ offset, data });

            const res = if (offset < 128)
                try self.handle_generic_cap_read(offset, data.len, io)
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

            log.debug("write from 0x{x}, data {x}\n", .{ offset, data });

            if (offset < 128) {
                try self.handle_generic_cap_write(offset, data, io);
            } else if (offset >= 256 and offset < 356) {
                // Do nothing here, since it should be handled by ioevent
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
                const num_queues = if (block.async)
                    1
                else
                    vm.config.smp;

                var device = try VirtioCore(Block).new(try Block.new(
                    block.path,
                    num_queues,
                    block.async,
                    io,
                ), alloc);
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
