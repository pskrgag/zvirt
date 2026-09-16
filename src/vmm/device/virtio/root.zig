//! Virtio device core

const std = @import("std");
const Block = @import("block.zig").Block;
const VirtQueue = @import("queue.zig").VirtQueue;
const Vm = @import("../../root.zig").Vm;
const Status = @import("common.zig").Status;
const StatusBits = @import("common.zig").StatusBits;

const log = std.log.scoped(.virtio);

pub const VirtioDeviceType = enum(u32) {
    BlockDevice = Block.MMIO_TYPE,
};

pub const VirtioDeviceInit = union(VirtioDeviceType) {
    BlockDevice: []const u8,
};

const VIRTIO_F_VERSION_1: u64 = 1 << 32;

pub const MAX_QUEUES_SUPPORTED = 1;

fn set_low(value: *u64, low: u32) void {
    value.* = (value.* & 0xffff_ffff_0000_0000) | @as(u64, low);
}

fn set_high(value: *u64, high: u32) void {
    value.* = (value.* & 0x0000_0000_ffff_ffff) |
        (@as(u64, high) << 32);
}

pub fn VirtioCore(comptime Device: type) type {
    return struct {
        device: Device,
        status: Status = 0,
        virt_queues: [MAX_QUEUES_SUPPORTED]VirtQueue =
            .{VirtQueue{}} ** MAX_QUEUES_SUPPORTED,
        alloc: std.heap.ArenaAllocator,
        device_features: u64 = Device.features() | VIRTIO_F_VERSION_1,
        driver_features: u64 = 0,

        const Self = @This();

        pub fn new(device: Device, alloc: std.mem.Allocator) Self {
            return .{ .device = device, .alloc = std.heap.ArenaAllocator.init(alloc) };
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
        pub fn notify_queue(self: *Self, idx: usize, vm: *Vm, io: std.Io) !bool {
            if (idx < self.device.max_queues()) {
                var reqs = try self.virt_queues[idx].kick(
                    vm.memory,
                    self.alloc.allocator(),
                );
                defer _ = self.alloc.reset(.retain_capacity);
                defer reqs.deinit(self.alloc.allocator());

                self.device.proccess_requests(reqs.items, io) catch {
                    @panic("todo");
                };

                var completed: usize = 0;

                for (reqs.items) |req| {
                    // Len == 0 means that request will be handled in async
                    if (req.len != 0) {
                        const res = self.virt_queues[idx].push_used(
                            req.head,
                            req.len,
                        );
                        std.debug.assert(res);

                        completed += 1;
                    }
                }

                return completed != 0;
            }

            return false;
        }

        pub fn handle_completion_event(self: *Self) !bool {
            try self.device.ack_event();

            var consumed = false;
            var batch: usize = 0;

            while (try self.device.pop_completion()) |async_result| {
                const res = self.virt_queues[0].push_used(
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

        pub fn queue(self: *Self, idx: usize) ?*VirtQueue {
            return if (idx < self.max_queues())
                return &self.virt_queues[idx]
            else
                null;
        }

        pub fn event_source(self: *const Self) std.posix.fd_t {
            return self.device.event_source();
        }

        pub fn max_queues(self: *const Self) usize {
            return self.device.max_queues();
        }

        pub fn deinit(self: *Self, io: std.Io) void {
            self.device.deinit(io);
            self.alloc.deinit();
        }
    };
}
