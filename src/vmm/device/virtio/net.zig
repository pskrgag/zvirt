//! Virtio net

const std = @import("std");
const queue = @import("queue.zig");
const Tap = @import("utils").Tap;
const VirtioCore = @import("root.zig").VirtioCore;
const NotifyResult = @import("root.zig").NotifyResult;
const Vm = @import("../../root.zig").Vm;

pub const c = @cImport({
    @cInclude("linux/virtio_net.h");
});

const VIRTIO_NET_F_MAC = 1 << 5;

pub const Net = struct {
    pub const Completion = struct {
        head: u16,
        len: u32,
    };

    config: c.virtio_net_config,
    tap: Tap,
    core: VirtioCore,

    pub const MMIO_TYPE = 0x1;

    const Self = @This();

    pub fn features() u32 {
        return VIRTIO_NET_F_MAC;
    }

    pub fn new(mac: [6]u8, iface: []const u8, alloc: std.mem.Allocator) !Self {
        var tap = try Tap.new(iface);
        errdefer tap.deinit();

        var config: c.virtio_net_config = undefined;

        @memset(std.mem.asBytes(&config), 0xff);
        config.mac = mac;

        return .{
            .config = config,
            .tap = tap,
            .core = try VirtioCore.new(Self.features(), 2, alloc),
        };
    }

    pub fn handle_completion_event(self: *Self, io: std.Io) !bool {
        _ = self;
        _ = io;

        @panic("todo");
    }

    pub fn handle_notify(self: *Self, fd: std.posix.fd_t, vm: *Vm, io: std.Io) !NotifyResult {
        _ = self;
        _ = fd;
        _ = vm;
        _ = io;

        @panic("todo");
    }

    pub fn completion_event_source(self: *const Self) ?std.posix.fd_t {
        _ = self;
        return null;
    }

    pub fn read_config(self: *const Self, offset: u32) u32 {
        return std.mem.readInt(u32, std.mem.asBytes(&self.config)[offset..][0..4], .little);
    }

    pub fn proccess_requests(self: *Self, reqs: []queue.RequestChain, io: std.Io) !void {
        _ = self;
        _ = reqs;
        _ = io;
    }

    pub fn pop_completion(self: *Self) !?Completion {
        _ = self;
        @panic("async is unsupported");
    }

    pub fn ack_event(self: *Self) !void {
        // Do nothing here...
        _ = self;
    }

    pub fn deinit(self: *Self, io: std.Io) void {
        _ = io;
        self.core.deinit();
        self.tap.deinit();
    }
};
