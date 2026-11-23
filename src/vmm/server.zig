// HTTP server for VMM

const utils = @import("utils");
const std = @import("std");
const Vm = @import("root.zig").Vm;
const net = std.Io.net;
const Epoll = utils.Epoll.Epoll;
const EpollEvent = utils.Epoll.Event;
const EventFd = utils.EventFd.EventFd;
const linux = std.os.linux;

const log = std.log.scoped(.server);

const FdType = enum(u2) {
    EventFd = 0,
    Listner = 1,
    Connection = 2,
};

const Token = packed struct(u64) {
    tp: FdType,
    fd: linux.fd_t,
    _pad: u30 = 0,
};

pub const Server = struct {
    vm: *Vm,
    server: std.Io.net.Server,
    eventfd: EventFd,
    worker: ?std.Thread = null,
    epoll: Epoll,

    const Self = @This();

    pub fn new(vm: *Vm, addr: []const u8, io: std.Io) !Self {
        std.Io.Dir.cwd().deleteFile(io, addr) catch {};
        const address = try std.Io.net.UnixAddress.init(addr);

        var server = try address.listen(io, .{});
        errdefer server.deinit(io);

        var eventfd = try EventFd.new(0);
        errdefer eventfd.deinit();

        var epoll = try Epoll.new();
        errdefer epoll.deinit();

        try epoll.add(server.socket.handle, @bitCast(Token{
            .tp = .Listner,
            .fd = server.socket.handle,
        }));
        try epoll.add(eventfd.fd, @bitCast(Token{
            .tp = .EventFd,
            .fd = eventfd.fd,
        }));

        return .{
            .vm = vm,
            .server = server,
            .eventfd = eventfd,
            .epoll = epoll,
        };
    }

    fn handle_latency(
        self: *Self,
        req: *std.http.Server.Request,
        i: anytype,
        alloc: std.mem.Allocator,
        io: std.Io,
    ) !void {
        var iter = i;
        const dev_name = iter.next() orelse return error.InvalidPath;
        const stat_name = iter.next() orelse return error.InvalidPath;

        const dev = self.vm.lookup_device(dev_name) orelse return error.InvalidPath;
        const latency = try dev.read_latency(dev.context, stat_name, io);

        const json = try std.json.Stringify.valueAlloc(alloc, latency, .{
            .whitespace = .indent_2,
        });
        defer alloc.free(json);

        try req.respond(json, .{ .status = .ok });
    }

    fn handle_stat(
        self: *Self,
        req: *std.http.Server.Request,
        i: anytype,
        alloc: std.mem.Allocator,
        io: std.Io,
    ) !void {
        var iter = i;
        const group = iter.next() orelse return error.InvalidPath;

        if (std.mem.eql(u8, group, "latency")) {
            try self.handle_latency(req, iter, alloc, io);
            return;
        }

        return error.InvalidPath;
    }

    fn handle_request(
        self: *Self,
        stream: std.Io.net.Stream,
        alloc: std.mem.Allocator,
        io: std.Io,
    ) !void {
        var reader_buf: [4096]u8 = undefined;
        var writer_buf: [4096]u8 = undefined;
        var reader_impl = stream.reader(io, &reader_buf);
        var writer_impl = stream.writer(io, &writer_buf);

        var http_server = std.http.Server.init(
            &reader_impl.interface,
            &writer_impl.interface,
        );

        var req = try http_server.receiveHead();

        errdefer {
            req.respond("", .{ .status = .bad_request }) catch {};
        }

        if (req.head.method != .GET) {
            return error.InvalidMethod;
        }

        const path = req.head.target;
        var iter = std.mem.splitScalar(u8, path, '/');

        // Skip empty
        const empty = iter.next() orelse return error.InvalidPath;
        if (empty.len != 0)
            return error.InvalidPath;

        const group = iter.next() orelse return error.InvalidPath;
        if (std.mem.eql(u8, group, "stat")) {
            try self.handle_stat(&req, iter, alloc, io);
            return;
        }

        return error.InvalidPath;
    }

    fn worker_thread(self: *Self, alloc: std.mem.Allocator, io: std.Io) !void {
        while (true) {
            var event_buffer: [1024]EpollEvent = undefined;

            const events = self.epoll.pwait(&event_buffer, -1, linux.sigfillset()) catch |e| {
                if (e == error.Interrupted)
                    continue;

                log.err("Server aborted by the epoll error\n", .{});
                return e;
            };

            for (events) |event| {
                const token: Token = @bitCast(event.data.u64);

                switch (token.tp) {
                    .EventFd => {
                        log.debug("Server stopped\n", .{});
                        return;
                    },
                    .Listner => {
                        log.debug("New connection \n", .{});

                        var session = self.server.accept(io) catch {
                            log.debug("Failed to accept new connection\n", .{});
                            continue;
                        };

                        self.epoll.add(session.socket.handle, @bitCast(Token{
                            .tp = .Connection,
                            .fd = session.socket.handle,
                        })) catch {
                            log.debug("Failed to add session to epoll\n", .{});
                            session.close(io);
                        };
                    },
                    .Connection => {
                        self.handle_request(
                            std.Io.net.Stream{
                                .socket = std.Io.net.Socket{
                                    .handle = token.fd,
                                    .address = undefined, // Is it fine? I guess so
                                },
                            },
                            alloc,
                            io,
                        ) catch {};
                    },
                }
            }
        }
    }

    pub fn start(self: *Self, io: std.Io, alloc: std.mem.Allocator) !void {
        self.worker = try std.Thread.spawn(.{}, Self.worker_thread, .{ self, alloc, io });
        try self.worker.?.setName(io, "http server");
    }

    pub fn deinit(self: *Self, io: std.Io) !void {
        try self.eventfd.notify();

        if (self.worker) |worker|
            worker.join();

        self.server.deinit(io);
        self.epoll.deinit();
        self.eventfd.deinit();
    }
};
