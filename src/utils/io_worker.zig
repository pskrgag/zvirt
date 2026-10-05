//! IO worker

const std = @import("std");
const Epoll = @import("epoll.zig").Epoll;
const EventFd = @import("eventfd.zig").EventFd;
const Thread = std.Thread;
const EpollEvent = @import("epoll.zig").Event;
const linux = std.os.linux;
const posix = std.posix;
const log = std.log.scoped(.io_worker);

const StopFlag = std.atomic.Value(bool);

pub const UserContext = u31;

const EpollToken = packed struct(u64) {
    fd: posix.fd_t,
    edge: u1,
    user_ctx: UserContext,
};

pub const Handler = struct {
    ctx: *anyopaque,
    f: *const fn (ctx: *anyopaque, io_ctx: UserContext) anyerror!void,
};

pub const IoWorker = struct {
    epoll: Epoll,
    shutdown_event: EventFd,
    threads: []Thread,
    stop_flag: StopFlag,
    start_event: std.Io.Event,
    handler: Handler,

    const Self = @This();

    fn worker(self: *Self, io: std.Io) !void {
        try self.start_event.wait(io);

        while (!self.stop_flag.load(.monotonic)) {
            var event_buffer: [1024]EpollEvent = undefined;

            const events = self.epoll.pwait(&event_buffer, -1, linux.sigfillset()) catch |e| {
                if (e == error.Interrupted)
                    continue;

                return e;
            };

            for (events) |event| {
                const token: EpollToken = @bitCast(event.data);

                if (self.stop_flag.load(.monotonic) or token.fd == self.shutdown_event.fd) {
                    return;
                }

                try self.handler.f(self.handler.ctx, token.user_ctx);
                try self.rearm_fd(token.fd, token.user_ctx, token.edge != 0);
            }
        }
    }

    pub fn new(num_threads: usize, handler: Handler, alloc: std.mem.Allocator, io: std.Io) !*Self {
        const self = try alloc.create(Self);
        errdefer alloc.destroy(self);

        const threads = try alloc.alloc(Thread, num_threads);
        errdefer alloc.free(threads);

        var epoll = try Epoll.new();
        errdefer epoll.deinit();

        var shutdown_event = try EventFd.new(0);
        errdefer shutdown_event.deinit();

        const shutdown_token = EpollToken{
            .fd = shutdown_event.fd,
            .edge = 0,
            .user_ctx = 0,
        };
        try epoll.add(shutdown_event.fd, @bitCast(shutdown_token));

        self.* = .{
            .epoll = epoll,
            .shutdown_event = shutdown_event,
            .threads = threads,
            .start_event = .unset,
            .stop_flag = .init(false),
            .handler = handler,
        };

        var threads_created: usize = 0;

        errdefer {
            self.stop_flag.store(true, .monotonic);
            self.start_event.set(io);

            for (0..threads_created) |i| {
                threads[i].join();
            }
        }

        for (0..num_threads) |i| {
            threads[i] = try Thread.spawn(.{}, Self.worker, .{ self, io });
            threads_created += 1;
        }

        return self;
    }

    pub fn start(self: *Self, io: std.Io) void {
        self.start_event.set(io);
    }

    fn rearm_fd(self: *Self, fd: posix.fd_t, user_ctx: UserContext, edge: bool) !void {
        const token = EpollToken{
            .fd = fd,
            .user_ctx = user_ctx,
            .edge = @intFromBool(edge),
        };
        const flags = linux.EPOLL.IN | linux.EPOLL.ONESHOT | if (edge) linux.EPOLL.ET else 0;

        try self.epoll.modify(fd, flags, @bitCast(token));
    }

    pub fn register_fd(self: *Self, fd: posix.fd_t, user_ctx: UserContext, edge: bool) !void {
        const token = EpollToken{
            .fd = fd,
            .user_ctx = user_ctx,
            .edge = @intFromBool(edge),
        };
        const flags = linux.EPOLL.IN | linux.EPOLL.ONESHOT | if (edge) linux.EPOLL.ET else 0;

        try self.epoll.add_with_events(fd, flags, @bitCast(token));
    }

    pub fn deinit(self: *Self, alloc: std.mem.Allocator, io: std.Io) void {
        self.stop_flag.store(true, .monotonic);
        self.start_event.set(io);

        while (true) {
            self.shutdown_event.notify() catch |err| {
                if (err == error.Interrupted) {
                    continue;
                }

                if (err == error.WouldBlock) {
                    break;
                }

                @panic("Failed to wake IO workers for shutdown");
            };
            break;
        }

        for (self.threads) |th| {
            th.join();
        }

        self.epoll.deinit();
        self.shutdown_event.deinit();
        alloc.free(self.threads);
        alloc.destroy(self);
    }
};

test "IO worker deinit before start" {
    var context: u8 = 0;
    const handler = struct {
        fn handle(_: *anyopaque, _: UserContext) !void {
            unreachable;
        }
    }.handle;

    const worker = try IoWorker.new(4, .{ .ctx = &context, .f = handler }, std.testing.allocator, std.testing.io);
    worker.deinit(std.testing.allocator, std.testing.io);
}

test "IO worker deinit after start" {
    var context: u8 = 0;
    const handler = struct {
        fn handle(_: *anyopaque, _: UserContext) !void {
            unreachable;
        }
    }.handle;

    for (0..32) |_| {
        const worker = try IoWorker.new(4, .{ .ctx = &context, .f = handler }, std.testing.allocator, std.testing.io);
        worker.start(std.testing.io);
        worker.deinit(std.testing.allocator, std.testing.io);
    }
}
