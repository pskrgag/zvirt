//! Virtio net

const std = @import("std");
const queue = @import("queue.zig");
const Tap = @import("utils").Tap;
const Mac = @import("utils").Mac;
const VirtioCore = @import("root.zig").VirtioCore;
const NotifyResult = @import("root.zig").NotifyResult;
const Vm = @import("../../root.zig").Vm;
const VirtQueueToken = @import("root.zig").VirtQueueToken;
const posix = std.posix;
const PciClass = @import("../pci/config.zig").PciClass;

const log = std.log.scoped(.virtio_net);

pub const c = @cImport({
    @cInclude("linux/virtio_net.h");
});

const VIRTIO_NET_F_MAC = 1 << 5;

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

pub const Net = struct {
    pub const Completion = struct {
        head: u16,
        len: u32,
    };

    tx_buffers: TxBuffers,
    config: c.virtio_net_config,
    tap: Tap,
    core: VirtioCore,

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
            (1 << c.VIRTIO_NET_F_GUEST_TSO4);
    }

    pub fn max_queues(self: *const Self) usize {
        _ = self;
        return 2;
    }

    pub fn new(mac: Mac, iface: []const u8, alloc: std.mem.Allocator) !Self {
        var tap = try Tap.new(iface, @sizeOf(c.virtio_net_hdr_mrg_rxbuf));
        errdefer tap.deinit();

        var config: c.virtio_net_config = undefined;

        @memset(std.mem.asBytes(&config), 0xff);
        config.mac = mac.mac;

        return .{
            .tx_buffers = try TxBuffers.new(alloc),
            .config = config,
            .tap = tap,
            .core = try VirtioCore.new(Self.features(), 2, alloc),
        };
    }

    fn tx_queue(self: *Self, io: std.Io) !VirtQueueToken {
        return self.core.get_queue(TX_QUEUE, io);
    }

    fn rx_queue(self: *Self, io: std.Io) !VirtQueueToken {
        return self.core.get_queue(RX_QUEUE, io);
    }

    fn try_read_packets(self: *Self, token: *const VirtQueueToken) !bool {
        var handled = false;

        while (self.tx_buffers.peek_chain()) |ch| {
            std.debug.assert(ch.buffer_count != 0);

            const frame_size = try self.tap.readv(&ch.buffer[0..ch.buffer_count]);
            if (frame_size == 0)
                break;

            const header: *c.virtio_net_hdr_mrg_rxbuf = @ptrCast(@alignCast(ch.buffer[0].base));
            header.num_buffers = 1;

            const res = token.state.queue.push_used(ch.head, @truncate(frame_size));
            std.debug.assert(res);

            handled = true;

            const tmp = self.tx_buffers.pop_chain();
            std.debug.assert(tmp != null);
        }

        return handled;
    }

    // Called on edge triggered tap event. It might be the case that no tx_buffers were supplied.
    // In such case buffer is left in kernel queue
    pub fn handle_completion_event(self: *Self, io: std.Io) !NotifyResult {
        const tx = try self.tx_queue(io);
        defer self.core.unlock_queue(tx, io);

        const processed = try self.try_read_packets(&tx);
        return .{ .proccessed = processed, .queue = TX_QUEUE };
    }

    fn proccess_rx_queue(self: *Self, vm: *Vm, token: *VirtQueueToken) !NotifyResult {
        var reqs = try token.state.queue.kick(
            vm.memory,
            token.state.alloc.allocator(),
        );

        defer _ = token.state.alloc.reset(.retain_capacity);
        defer reqs.deinit(token.state.alloc.allocator());

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

            try self.tx_buffers.push(chain);
        }

        // Consume pending in-kernel tap packets if any.
        const processed = try self.try_read_packets(token);
        return .{ .queue = token.idx, .proccessed = processed };
    }

    fn proccess_tx_queue(self: *Self, vm: *Vm, token: *VirtQueueToken) !NotifyResult {
        var reqs = try token.state.queue.kick(
            vm.memory,
            token.state.alloc.allocator(),
        );

        defer _ = token.state.alloc.reset(.retain_capacity);
        defer reqs.deinit(token.state.alloc.allocator());

        for (reqs.items) |ch| {
            const rqs = ch.get_requests();
            var buffers: [16]posix.iovec_const = undefined;

            for (rqs, 0..) |r, i| {
                const slice = r.as_ro();

                buffers[i].base = slice.ptr;
                buffers[i].len = slice.len;
            }

            const res = try self.tap.writev(buffers[0..rqs.len]);
            _ = res;

            const sent = token.state.queue.push_used(
                ch.head,
                0,
            );
            std.debug.assert(sent);
        }

        return .{ .proccessed = true, .queue = token.idx };
    }

    pub fn handle_notify(self: *Self, queue_idx: u19, vm: *Vm, io: std.Io) !NotifyResult {
        var token = try self.core.notified_queue(queue_idx, io);
        defer self.core.unlock_queue(token, io);

        if (token.idx == 0) {
            return self.proccess_rx_queue(vm, &token);
        } else {
            return self.proccess_tx_queue(vm, &token);
        }
    }

    pub fn completion_event_source(self: *const Self) ?struct { fd: std.posix.fd_t, edge: bool } {
        return .{ .fd = self.tap.fd, .edge = true };
    }

    pub fn read_config(self: *const Self, offset: u32) u32 {
        return std.mem.readInt(u32, std.mem.asBytes(&self.config)[offset..][0..4], .little);
    }

    pub fn deinit(self: *Self, alloc: std.mem.Allocator, io: std.Io) void {
        _ = io;

        self.core.deinit();
        self.tap.deinit();
        self.tx_buffers.deinit(alloc);
    }
};
