//! Virtio device core

const std = @import("std");
const Block = @import("block.zig").Block;
const Net = @import("net.zig").Net;
const VirtQueue = @import("queue.zig").VirtQueue;
const Vm = @import("../../root.zig").Vm;
const GuestMemory = @import("../../memory.zig").GuestMemory;
const Mutex = std.Io.Mutex;
const EventFd = @import("utils").EventFd.EventFd;
const Mac = @import("utils").Mac;
const queue = @import("queue.zig");
pub const c = @cImport({
    @cInclude("linux/virtio_ring.h");
    @cInclude("linux/virtio_config.h");
});

const log = std.log.scoped(.virtio);

pub const Status = u8;

pub const StatusBits = enum(u8) {
    Ack = 1 << 0,
    Driver = 1 << 1,
    DriverOk = 1 << 2,
    FeatureOk = 1 << 3,
    DeviceNeedsReset = 1 << 6,
    Failed = 1 << 7,
};

pub const VirtioDeviceType = enum(u32) {
    BlockDevice = Block.MMIO_TYPE,
    NetDevice = Net.MMIO_TYPE,
};

pub const VirtioDeviceInit = union(VirtioDeviceType) {
    BlockDevice: struct { path: []const u8, async: bool },
    NetDevice: struct {
        mac: Mac,
        iface: []const u8,
    },
};

const VIRTIO_F_VERSION_1: u64 = 1 << 32;

pub const MAX_QUEUES_SUPPORTED = 2048;

fn set_low(value: *u64, low: u32) void {
    value.* = (value.* & 0xffff_ffff_0000_0000) | @as(u64, low);
}

fn set_high(value: *u64, high: u32) void {
    value.* = (value.* & 0x0000_0000_ffff_ffff) |
        (@as(u64, high) << 32);
}

const VirtQueueState = struct {
    lock: Mutex = .init,
    queue: ?VirtQueue = null,

    // Invalid PA
    //
    // TODO: introduce PA abstraction one day...
    desc_ring: u64 = std.math.maxInt(u64),
    available_ring: u64 = std.math.maxInt(u64),
    used_ring: u64 = std.math.maxInt(u64),
    elements: u32 = queue.MAX_QUEUE_ELEMENTS,

    alloc: std.heap.ArenaAllocator,
    notifyfd: EventFd,
};

pub const NotifyResult = struct {
    notify: bool,
    queue: usize,
};

pub const VirtQueueToken = struct {
    queue: *VirtQueue,
    alloc: *std.heap.ArenaAllocator,

    idx: usize,
};

pub const VirtioCore = struct {
    status: Status = 0,
    virt_queues: [MAX_QUEUES_SUPPORTED]VirtQueueState,
    device_features: u64,
    driver_features: u64 = 0,
    queues: usize,

    const Self = @This();

    pub fn new(
        features: u64,
        queues: usize,
        alloc: std.mem.Allocator,
    ) !Self {
        if (queues > MAX_QUEUES_SUPPORTED)
            return error.TooManyQueues;

        var state: [MAX_QUEUES_SUPPORTED]VirtQueueState = @splat(.{
            .alloc = std.heap.ArenaAllocator.init(alloc),
            .notifyfd = undefined,
        });

        var notifyfd_count: usize = 0;

        errdefer for (state[0..notifyfd_count]) |*s| {
            s.notifyfd.deinit();
        };

        while (notifyfd_count < queues) {
            state[notifyfd_count].notifyfd = try EventFd.new(0);
            notifyfd_count += 1;
        }

        return .{
            .device_features = features | (1 << c.VIRTIO_F_VERSION_1) | (1 << c.VIRTIO_RING_F_EVENT_IDX),
            .virt_queues = state,
            .queues = queues,
        };
    }

    pub fn notifyfd_for_queue(self: *const Self, idx: usize) !*const EventFd {
        if (idx >= self.max_queues())
            return error.InvalidQueue;

        return &self.virt_queues[idx].notifyfd;
    }

    pub fn get_queue_ready(self: *Self, idx: usize, io: std.Io) !u32 {
        if (idx >= self.max_queues())
            return 0;

        const state = &self.virt_queues[idx];
        try state.lock.lock(io);
        defer state.lock.unlock(io);

        return @intFromBool(state.queue != null);
    }

    pub fn get_queue_num(self: *Self, idx: usize, io: std.Io) !u32 {
        if (idx >= self.max_queues())
            return 0;

        const state = &self.virt_queues[idx];
        try state.lock.lock(io);
        defer state.lock.unlock(io);

        return state.elements;
    }

    pub fn set_queue_ready(self: *Self, idx: usize, memory: *GuestMemory, val: u32, io: std.Io) !void {
        if (idx >= self.max_queues())
            return;

        const state = &self.virt_queues[idx];
        try state.lock.lock(io);
        defer state.lock.unlock(io);

        if (val == 0) {
            state.queue = null;
            return;
        }

        const suppress = (self.driver_features & (1 << c.VIRTIO_RING_F_EVENT_IDX)) != 0;

        state.queue = try VirtQueue.new(
            memory,
            val,
            state.desc_ring,
            state.available_ring,
            state.used_ring,
            state.elements,
            suppress,
        );
    }

    pub fn set_queue_num(self: *Self, idx: usize, val: u32, io: std.Io) !void {
        if (idx >= self.max_queues())
            return;

        const state = &self.virt_queues[idx];
        try state.lock.lock(io);
        defer state.lock.unlock(io);

        if (val <= queue.MAX_QUEUE_ELEMENTS and std.math.isPowerOfTwo(val)) {
            state.elements = val;
        }
    }

    pub fn set_queue_desc_low(self: *Self, idx: usize, val: u32, io: std.Io) !void {
        if (idx >= self.max_queues())
            return;

        const state = &self.virt_queues[idx];
        try state.lock.lock(io);
        defer state.lock.unlock(io);

        set_low(&state.desc_ring, val);
    }

    pub fn set_queue_desc_high(self: *Self, idx: usize, val: u32, io: std.Io) !void {
        if (idx >= self.max_queues())
            return;

        const state = &self.virt_queues[idx];
        try state.lock.lock(io);
        defer state.lock.unlock(io);

        set_high(&state.desc_ring, val);
    }

    pub fn set_queue_avail_low(self: *Self, idx: usize, val: u32, io: std.Io) !void {
        if (idx >= self.max_queues())
            return;

        const state = &self.virt_queues[idx];
        try state.lock.lock(io);
        defer state.lock.unlock(io);

        set_low(&state.available_ring, val);
    }

    pub fn set_queue_avail_high(self: *Self, idx: usize, val: u32, io: std.Io) !void {
        if (idx >= self.max_queues())
            return;

        const state = &self.virt_queues[idx];
        try state.lock.lock(io);
        defer state.lock.unlock(io);

        set_high(&state.available_ring, val);
    }

    pub fn set_queue_used_low(self: *Self, idx: usize, val: u32, io: std.Io) !void {
        if (idx >= self.max_queues())
            return;

        const state = &self.virt_queues[idx];
        try state.lock.lock(io);
        defer state.lock.unlock(io);

        set_low(&state.used_ring, val);
    }

    pub fn set_queue_used_high(self: *Self, idx: usize, val: u32, io: std.Io) !void {
        if (idx >= self.max_queues())
            return;

        const state = &self.virt_queues[idx];
        try state.lock.lock(io);
        defer state.lock.unlock(io);

        set_high(&state.used_ring, val);
    }

    pub fn update_driver_feats(self: *Self, bits: u32, high: bool) void {
        if (high)
            set_high(&self.driver_features, bits)
        else
            set_low(&self.driver_features, bits);

        self.update_status(
            .FeatureOk,
            (self.driver_features & ~self.device_features) == 0,
        );
    }

    pub fn update_status(self: *Self, bit: StatusBits, set: bool) void {
        if (set) {
            self.status |= @intFromEnum(bit);
        } else {
            self.status &= ~@intFromEnum(bit);
        }
    }

    pub fn get_queue(self: *Self, idx: usize, io: std.Io) !VirtQueueToken {
        if (idx >= self.max_queues()) {
            return error.InvalidQueue;
        }

        const state = &self.virt_queues[idx];

        try state.lock.lock(io);
        errdefer state.lock.unlock(io);

        if (state.queue) |*live_queue| {
            return .{ .queue = live_queue, .alloc = &state.alloc, .idx = idx };
        }

        return error.QueueNotReady;
    }

    pub fn unlock_queue(self: *Self, token: VirtQueueToken, io: std.Io) void {
        self.virt_queues[token.idx].lock.unlock(io);
    }

    pub fn max_queues(self: *const Self) usize {
        return self.queues;
    }

    pub fn notified_queue(self: *Self, idx: usize, io: std.Io) !VirtQueueToken {
        if (idx >= self.max_queues()) {
            return error.InvalidNotify;
        }

        _ = try self.virt_queues[idx].notifyfd.read();
        return self.get_queue(idx, io);
    }

    pub fn deinit(self: *Self) void {
        for (self.virt_queues[0..self.max_queues()]) |*s| {
            s.notifyfd.deinit();
        }

        for (self.virt_queues) |state| {
            state.alloc.deinit();
        }
    }
};
