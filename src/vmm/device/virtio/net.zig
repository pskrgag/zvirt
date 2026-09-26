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
    buffer: [16]posix.iovec,
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

    // TODO: maybe smth more specific? Like arena? But on the other hand, it's not clear when to
    // flush it, since it's completely possible that at least one descriptor would be active, which
    // may consume unbounded memory...
    //
    // It's possible to flush it when threshold is reached. Need to bench it.
    alloc: std.mem.Allocator,

    pub const MMIO_TYPE = 0x1;
    pub const PCI_DEVICE_ID = 0x1041;
    pub const PCI_SUBCLASS = 0x0;
    pub const PCI_CLASS: PciClass = .Nic;

    const Self = @This();

    pub fn features() u32 {
        return VIRTIO_NET_F_MAC;
    }

    pub fn max_queues(self: *const Self) usize {
        _ = self;
        return 2;
    }

    pub fn new(mac: Mac, iface: []const u8, alloc: std.mem.Allocator) !Self {
        var tap = try Tap.new(iface);
        errdefer tap.deinit();

        var config: c.virtio_net_config = undefined;

        @memset(std.mem.asBytes(&config), 0xff);
        config.mac = mac.mac;

        return .{
            .tx_buffers = try TxBuffers.new(alloc),
            .config = config,
            .tap = tap,
            .core = try VirtioCore.new(Self.features(), 2, alloc),
            .alloc = alloc,
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
            const frame_size = try self.tap.readv(&ch.buffer[0..ch.buffer_count]);
            if (frame_size == 0)
                break;

            const header: *c.virtio_net_hdr_mrg_rxbuf = @ptrCast(@alignCast(ch.buffer[0].base - @sizeOf(c.virtio_net_hdr_mrg_rxbuf)));

            header.* = std.mem.zeroes(c.virtio_net_hdr_mrg_rxbuf);
            header.num_buffers = 1;
            header.hdr.gso_type = 0;

            const res = token.state.queue.push_used(ch.head, @truncate(frame_size + @sizeOf(c.virtio_net_hdr_mrg_rxbuf)));
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
                const offset: usize = if (i == 0) @sizeOf(c.virtio_net_hdr_mrg_rxbuf) else 0;

                chain.buffer[i].base = slice.ptr + offset;
                chain.buffer[i].len = slice.len - offset;
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
                const offset: usize = if (i == 0) @sizeOf(c.virtio_net_hdr_mrg_rxbuf) else 0;

                buffers[i].base = slice.ptr + offset;
                buffers[i].len = slice.len - offset;
            }

            const res = try self.tap.writev(buffers[0..rqs.len]);

            const sent = token.state.queue.push_used(
                ch.head,
                @truncate(res),
            );
            std.debug.assert(sent);
        }

        return .{ .proccessed = true, .queue = token.idx };
    }

    pub fn handle_notify(self: *Self, fd: std.posix.fd_t, vm: *Vm, io: std.Io) !NotifyResult {
        var token = try self.core.notified_queue(fd, io);
        defer self.core.unlock_queue(token, io);

        log.debug("Queue {} kick\n", .{token.idx});

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

    pub fn deinit(self: *Self, io: std.Io) void {
        _ = io;
        self.core.deinit();
        self.tap.deinit();
        self.tx_buffers.deinit(self.alloc);
    }
};
