//! Virtio device core

const std = @import("std");
const Block = @import("block.zig").Block;
const Net = @import("net.zig").Net;
const VirtQueue = @import("queue.zig").VirtQueue;
const Vm = @import("../../root.zig").Vm;
const GuestMemory = @import("../../memory.zig").GuestMemory;
const Status = @import("common.zig").Status;
const StatusBits = @import("common.zig").StatusBits;
const Mutex = std.Io.Mutex;
const EventFd = @import("utils").EventFd.EventFd;

const log = std.log.scoped(.virtio);

pub const VirtioDeviceType = enum(u32) {
    BlockDevice = Block.MMIO_TYPE,
    NetDevice = Net.MMIO_TYPE,
};

pub const VirtioDeviceInit = union(VirtioDeviceType) {
    BlockDevice: struct { path: []const u8, async: bool },
    NetDevice: struct {
        mac: [6]u8,
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
    queue: VirtQueue = .{},
    alloc: std.heap.ArenaAllocator,
    notifyfd: EventFd,
};

pub const NotifyResult = struct {
    proccessed: bool,
    queue: usize,
};

pub fn VirtioCore(comptime Device: type) type {
    return struct {
        device: Device,
        status: Status = 0,
        virt_queues: [MAX_QUEUES_SUPPORTED]VirtQueueState,
        device_features: u64 = Device.features() | VIRTIO_F_VERSION_1,
        driver_features: u64 = 0,

        const Self = @This();

        pub fn new(device: Device, alloc: std.mem.Allocator) !Self {
            var state: [MAX_QUEUES_SUPPORTED]VirtQueueState = @splat(.{
                .alloc = std.heap.ArenaAllocator.init(alloc),
                .notifyfd = undefined,
            });

            var notifyfd_count: usize = 0;

            errdefer for (state[0..notifyfd_count]) |*s| {
                s.notifyfd.deinit();
            };

            while (notifyfd_count < device.max_queues()) {
                state[notifyfd_count].notifyfd = try EventFd.new(0);
                notifyfd_count += 1;
            }

            return .{
                .device = device,
                .virt_queues = state,
            };
        }

        pub fn notifyfd_for_queue(self: *const Self, idx: usize) !*const EventFd {
            if (idx >= self.device.max_queues())
                return error.InvalidQueue;

            return &self.virt_queues[idx].notifyfd;
        }

        pub fn get_queue_ready(self: *Self, idx: usize, io: std.Io) !u32 {
            if (idx >= self.max_queues())
                return 0;

            const state = &self.virt_queues[idx];
            try state.lock.lock(io);
            defer state.lock.unlock(io);

            return state.queue.is_ready;
        }

        pub fn get_queue_num(self: *Self, idx: usize, io: std.Io) !u32 {
            if (idx >= self.max_queues())
                return 0;

            const state = &self.virt_queues[idx];
            try state.lock.lock(io);
            defer state.lock.unlock(io);

            return state.queue.elements;
        }

        pub fn set_queue_ready(self: *Self, idx: usize, memory: *GuestMemory, val: u32, io: std.Io) !void {
            if (idx >= self.max_queues())
                return;

            const state = &self.virt_queues[idx];
            try state.lock.lock(io);
            defer state.lock.unlock(io);

            try state.queue.ready(memory, val);
        }

        pub fn set_queue_num(self: *Self, idx: usize, val: u32, io: std.Io) !void {
            if (idx >= self.max_queues())
                return;

            const state = &self.virt_queues[idx];
            try state.lock.lock(io);
            defer state.lock.unlock(io);

            try state.queue.set_elements(val);
        }

        pub fn set_queue_desc_low(self: *Self, idx: usize, val: u32, io: std.Io) !void {
            if (idx >= self.max_queues())
                return;

            const state = &self.virt_queues[idx];
            try state.lock.lock(io);
            defer state.lock.unlock(io);

            set_low(&state.queue.desc_ring, val);
        }

        pub fn set_queue_desc_high(self: *Self, idx: usize, val: u32, io: std.Io) !void {
            if (idx >= self.max_queues())
                return;

            const state = &self.virt_queues[idx];
            try state.lock.lock(io);
            defer state.lock.unlock(io);

            set_high(&state.queue.desc_ring, val);
        }

        pub fn set_queue_avail_low(self: *Self, idx: usize, val: u32, io: std.Io) !void {
            if (idx >= self.max_queues())
                return;

            const state = &self.virt_queues[idx];
            try state.lock.lock(io);
            defer state.lock.unlock(io);

            set_low(&state.queue.available_ring, val);
        }

        pub fn set_queue_avail_high(self: *Self, idx: usize, val: u32, io: std.Io) !void {
            if (idx >= self.max_queues())
                return;

            const state = &self.virt_queues[idx];
            try state.lock.lock(io);
            defer state.lock.unlock(io);

            set_high(&state.queue.available_ring, val);
        }

        pub fn set_queue_used_low(self: *Self, idx: usize, val: u32, io: std.Io) !void {
            if (idx >= self.max_queues())
                return;

            const state = &self.virt_queues[idx];
            try state.lock.lock(io);
            defer state.lock.unlock(io);

            set_low(&state.queue.used_ring, val);
        }

        pub fn set_queue_used_high(self: *Self, idx: usize, val: u32, io: std.Io) !void {
            if (idx >= self.max_queues())
                return;

            const state = &self.virt_queues[idx];
            try state.lock.lock(io);
            defer state.lock.unlock(io);

            set_high(&state.queue.used_ring, val);
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

        // Returns true if used queue was updated
        fn notify_queue(self: *Self, idx: usize, vm: *Vm, io: std.Io) !bool {
            std.debug.assert(idx < self.device.max_queues());

            const state = &self.virt_queues[idx];

            var reqs = try state.queue.kick(
                vm.memory,
                state.alloc.allocator(),
            );
            defer _ = state.alloc.reset(.retain_capacity);
            defer reqs.deinit(state.alloc.allocator());

            self.device.proccess_requests(reqs.items, io) catch {
                @panic("todo");
            };

            var completed: usize = 0;

            for (reqs.items) |req| {
                // Len == 0 means that request will be handled in async
                if (req.len != 0) {
                    const res = state.queue.push_used(
                        req.head,
                        req.len,
                    );
                    std.debug.assert(res);

                    completed += 1;
                }
            }

            return completed != 0;
        }

        pub fn handle_completion_event(self: *Self, io: std.Io) !bool {
            try self.device.ack_event();

            // NOTE: support only one queue in async mode (do we need more? I don't think so)
            std.debug.assert(self.max_queues() == 1);

            var consumed = false;
            var batch: usize = 0;

            while (try self.device.pop_completion()) |async_result| {
                const state = &self.virt_queues[0];

                try state.lock.lock(io);
                defer state.lock.unlock(io);

                const res = state.queue.push_used(
                    async_result.head,
                    async_result.len,
                );
                std.debug.assert(res);

                batch += 1;
                consumed = true;
            }

            if (consumed) {
                log.debug("batched {}\n", .{batch});
            }

            return consumed;
        }

        pub fn read_config(self: *const Self, offset: u32) u32 {
            return self.device.read_config(offset);
        }

        pub fn completion_event_source(self: *const Self) ?std.posix.fd_t {
            return self.device.completion_event_source();
        }

        pub fn max_queues(self: *const Self) usize {
            return self.device.max_queues();
        }

        pub fn handle_notify(self: *Self, fd: std.posix.fd_t, vm: *Vm, io: std.Io) !NotifyResult {
            for (self.virt_queues[0..self.device.max_queues()], 0..) |*state, queue_idx| {
                if (state.notifyfd.as_fd() == fd) {
                    try state.lock.lock(io);
                    defer state.lock.unlock(io);

                    _ = try state.notifyfd.read();
                    const proccessed = try self.notify_queue(queue_idx, vm, io);

                    return .{ .proccessed = proccessed, .queue = queue_idx };
                }
            }

            return error.InvalidNotify;
        }

        pub fn deinit(self: *Self, io: std.Io) void {
            for (self.virt_queues[0..self.device.max_queues()]) |*s| {
                s.notifyfd.deinit();
            }

            self.device.deinit(io);

            for (self.virt_queues) |state| {
                state.alloc.deinit();
            }
        }
    };
}
