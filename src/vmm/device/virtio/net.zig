//! Virtio net

const std = @import("std");
const queue = @import("queue.zig");
const Tap = @import("utils").Tap;
const Mac = @import("utils").Mac;
const VirtioCore = @import("root.zig").VirtioCore;
const NotifyResult = @import("root.zig").NotifyResult;
const EventSources = @import("event_source.zig").EventSources;
const Vm = @import("../../root.zig").Vm;
const VirtQueueToken = @import("root.zig").VirtQueueToken;
const posix = std.posix;
const PciClass = @import("../pci/config.zig").PciClass;

const log = std.log.scoped(.virtio_net);

pub const c = @cImport({
    @cInclude("linux/virtio_net.h");
    @cInclude("linux/virtio_ring.h");
});

const TxChain = struct {
    buffer: [32]posix.iovec,
    buffer_count: usize,
    head: u16,
};

comptime {
    std.debug.assert(@sizeOf(c.virtio_net_hdr_mrg_rxbuf) == 12);
}

const TxBuffers = struct {
    buffer: []TxChain = undefined,
    queue: std.Deque(TxChain),

    const Self = @This();

    fn new(alloc: std.mem.Allocator) !Self {
        const buffer = try alloc.alloc(TxChain, 1000);

        return .{ .buffer = buffer, .queue = std.Deque(TxChain).initBuffer(buffer) };
    }

    fn push(self: *Self, chain: TxChain) !void {
        try self.queue.pushBackBounded(chain);
    }

    fn deinit(self: *Self, alloc: std.mem.Allocator) void {
        alloc.free(self.buffer);
    }

    fn peek_chain(self: *Self) ?*TxChain {
        return self.queue.frontPtr();
    }

    fn pop_chain(self: *Self) ?TxChain {
        return self.queue.popFront();
    }
};

const TX_QUEUE = 0;
const RX_QUEUE = 1;

const MAX_QUEUE_PAIRS = 32;

const TapContext = struct {
    tap: Tap,
    tx_buffers: TxBuffers,

    const Self = @This();

    fn new(tap: Tap, alloc: std.mem.Allocator) !Self {
        return .{ .tap = tap, .tx_buffers = try TxBuffers.new(alloc) };
    }

    fn deinit(self: *Self, alloc: std.mem.Allocator) void {
        self.tap.deinit();
        self.tx_buffers.deinit(alloc);
    }
};

pub const Net = struct {
    pub const Completion = struct {
        head: u16,
        len: u32,
    };

    config: c.virtio_net_config,
    taps: [MAX_QUEUE_PAIRS]TapContext,
    core: VirtioCore,
    queue_pairs: usize,

    pub const MMIO_TYPE = 0x1;
    pub const PCI_DEVICE_ID = 0x1041;
    pub const PCI_SUBCLASS = 0x0;
    pub const PCI_CLASS: PciClass = .Nic;

    const Self = @This();

    pub fn features() u32 {
        return (1 << c.VIRTIO_NET_F_MAC) |
            (1 << c.VIRTIO_NET_F_GUEST_CSUM) |
            (1 << c.VIRTIO_NET_F_CSUM) |
            (1 << c.VIRTIO_NET_F_HOST_TSO4) |
            (1 << c.VIRTIO_NET_F_GUEST_TSO4) |
            (1 << c.VIRTIO_NET_F_HOST_TSO6) |
            (1 << c.VIRTIO_NET_F_GUEST_TSO6) |
            (1 << c.VIRTIO_NET_F_MQ) |
            (1 << c.VIRTIO_NET_F_CTRL_VQ);
    }

    pub fn max_queues_ex(queue_pairs: usize) usize {
        const has_control = queue_pairs > 1;

        return queue_pairs * 2 + @intFromBool(has_control);
    }

    pub fn max_queues(self: *const Self) usize {
        return Self.max_queues_ex(self.queue_pairs);
    }

    pub fn new(mac: Mac, iface: []const u8, queue_pairs: usize, alloc: std.mem.Allocator) !Self {
        var taps: [MAX_QUEUE_PAIRS]TapContext = undefined;
        var opened_pairs: usize = 0;

        errdefer {
            for (0..opened_pairs) |i|
                taps[i].deinit(alloc);
        }

        for (0..queue_pairs) |i| {
            var tap = try Tap.new(iface, @sizeOf(c.virtio_net_hdr_mrg_rxbuf), queue_pairs != 1);
            errdefer tap.deinit();

            taps[i] = try TapContext.new(tap, alloc);
            opened_pairs += 1;
        }

        var config: c.virtio_net_config = undefined;

        @memset(std.mem.asBytes(&config), 0xff);
        config.mac = mac.mac;
        config.max_virtqueue_pairs = @intCast(queue_pairs);

        return .{
            .config = config,
            .taps = taps,
            .core = try VirtioCore.new(Self.features(), Self.max_queues_ex(queue_pairs), alloc),
            .queue_pairs = queue_pairs,
        };
    }

    fn has_control_queue(self: *const Self) bool {
        return self.core.driver_features & (1 << c.VIRTIO_NET_F_CTRL_VQ) != 0;
    }

    fn try_read_packets(self: *Self, pair: usize, token: *const VirtQueueToken) !bool {
        var notify = false;
        const tap = &self.taps[pair];

        while (tap.tx_buffers.peek_chain()) |ch| {
            std.debug.assert(ch.buffer_count != 0);

            const frame_size = try tap.tap.readv(&ch.buffer[0..ch.buffer_count]);
            if (frame_size == 0)
                break;

            const header: *c.virtio_net_hdr_mrg_rxbuf = @ptrCast(@alignCast(ch.buffer[0].base));
            header.num_buffers = 1;

            notify |= token.queue.push_used(ch.head, @truncate(frame_size));

            const tmp = tap.tx_buffers.pop_chain();
            std.debug.assert(tmp != null);
        }

        return notify;
    }

    // Called on edge triggered tap event. It might be the case that no tx_buffers were supplied.
    // In such case buffer is left in kernel queue
    pub fn handle_completion_event(self: *Self, id: usize, io: std.Io) !NotifyResult {
        const tx = self.core.get_queue(id * 2, io) catch return .{ .queue = 0, .notify = false };
        defer self.core.unlock_queue(tx, io);

        const processed = try self.try_read_packets(id, &tx);
        return .{ .notify = processed, .queue = id * 2 };
    }

    fn proccess_rx_queue(self: *Self, pair: usize, vm: *Vm, token: *VirtQueueToken) !NotifyResult {
        var reqs = try token.queue.kick(
            vm.memory,
            token.alloc.allocator(),
        );

        const tap = &self.taps[pair];

        defer _ = token.alloc.reset(.retain_capacity);
        defer reqs.deinit(token.alloc.allocator());

        for (reqs.items) |ch| {
            const rqs = ch.get_requests();
            var chain = TxChain{
                .buffer = undefined,
                .buffer_count = rqs.len,
                .head = ch.head,
            };

            for (rqs, 0..) |r, i| {
                const slice = r.as_rw() orelse return error.InvalidBuffer;

                chain.buffer[i].base = slice.ptr;
                chain.buffer[i].len = slice.len;
            }

            try tap.tx_buffers.push(chain);
        }

        // Consume pending in-kernel tap packets if any.
        const processed = try self.try_read_packets(pair, token);
        return .{ .queue = token.idx, .notify = processed };
    }

    fn proccess_tx_queue(self: *Self, pair: usize, vm: *Vm, token: *VirtQueueToken) !NotifyResult {
        var reqs = try token.queue.kick(
            vm.memory,
            token.alloc.allocator(),
        );
        var notify = false;
        const tap = &self.taps[pair];

        defer _ = token.alloc.reset(.retain_capacity);
        defer reqs.deinit(token.alloc.allocator());

        for (reqs.items) |ch| {
            const rqs = ch.get_requests();
            var buffers: [32]posix.iovec_const = undefined;

            for (rqs, 0..) |r, i| {
                const slice = r.as_ro();

                buffers[i].base = slice.ptr;
                buffers[i].len = slice.len;
            }

            const res = try tap.tap.writev(buffers[0..rqs.len]);
            _ = res;

            notify |= token.queue.push_used(
                ch.head,
                0,
            );
        }

        return .{ .notify = notify, .queue = token.idx };
    }

    fn handle_ctrl_mq(
        self: *Self,
        header: *const c.virtio_net_ctrl_hdr,
        reqs: []const queue.Request,
    ) !u32 {
        _ = self;

        std.debug.assert(header.class == c.VIRTIO_NET_CTRL_MQ);

        switch (header.cmd) {
            c.VIRTIO_NET_CTRL_MQ_VQ_PAIRS_SET => {
                const payload: *const u16 = blk: {
                    const payload = reqs[0].as_ro();

                    if (payload.len != @sizeOf(u16))
                        return error.InvalidFormat;

                    break :blk @ptrCast(@alignCast(payload));
                };
                const ack: *u8 = blk: {
                    const ack = reqs[1].as_rw() orelse return error.InvalidFormat;

                    if (ack.len != @sizeOf(u8))
                        return error.InvalidFormat;

                    break :blk @ptrCast(ack);
                };

                log.debug("requested pairs {}", .{payload.*});
                ack.* = c.VIRTIO_NET_OK;
                return 1;
            },
            else => @panic("todo"),
        }
    }

    fn proccess_control_queue(self: *Self, vm: *Vm, token: *VirtQueueToken) !NotifyResult {
        const reqs = try token.queue.kick(
            vm.memory,
            token.alloc.allocator(),
        );
        var notify = false;

        for (reqs.items) |ch| {
            const rqs = ch.get_requests();

            // NOTE: spec allows header to be spread across different descriptors. But hey, I don't
            // believe that people can be THAT insane.
            //
            // Linux's written by sane people, so keep that semantics
            if (rqs.len != 3)
                return error.InvalidFormat;

            const header: *const c.virtio_net_ctrl_hdr = blk: {
                const header = rqs[0].as_ro();
                if (header.len != @sizeOf(c.virtio_net_ctrl_hdr)) {
                    return error.InvalidFormat;
                }

                break :blk @ptrCast(header.ptr);
            };

            const len = switch (header.class) {
                c.VIRTIO_NET_CTRL_MQ => try self.handle_ctrl_mq(header, rqs[1..]),
                else => return error.UnknownCmd,
            };

            notify |= token.queue.push_used(ch.head, len);
        }

        std.debug.assert(self.has_control_queue());
        return .{ .queue = self.queue_pairs * 2, .notify = notify };
    }

    pub fn handle_notify(self: *Self, queue_idx: u19, vm: *Vm, io: std.Io) !NotifyResult {
        var token = try self.core.notified_queue(queue_idx, io);
        defer self.core.unlock_queue(token, io);

        const pair = queue_idx / 2;

        if (queue_idx == self.queue_pairs * 2) {
            return self.proccess_control_queue(vm, &token);
        } else if (queue_idx % 2 == 1) {
            return self.proccess_tx_queue(pair, vm, &token);
        } else if (queue_idx % 2 == 0) {
            return self.proccess_rx_queue(pair, vm, &token);
        } else {
            @panic("Unknown queue");
        }
    }

    pub fn completion_event_source(self: *const Self) ?EventSources(MAX_QUEUE_PAIRS) {
        var events: EventSources(MAX_QUEUE_PAIRS) = .{ .count = self.queue_pairs };

        for (self.taps[0..self.queue_pairs], 0..) |tap, i| {
            events.entries[i] = .{ .fd = tap.tap.fd, .edge = true };
        }

        return events;
    }

    pub fn read_config(self: *const Self, offset: u32) u32 {
        return std.mem.readInt(u32, std.mem.asBytes(&self.config)[offset..][0..4], .little);
    }

    pub fn deinit(self: *Self, alloc: std.mem.Allocator, io: std.Io) void {
        _ = io;

        self.core.deinit();

        for (0..self.queue_pairs) |i| {
            self.taps[i].deinit(alloc);
        }
    }
};
