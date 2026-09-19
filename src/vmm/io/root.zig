//! Async IO

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const EventFd = @import("utils").EventFd.EventFd;

const log = std.log.scoped(.file_engine);

fn token_to_u64(token: anytype) u64 {
    const T = @TypeOf(token);

    return switch (@typeInfo(T)) {
        .pointer => |p| if (p.size == .slice)
            @compileError("I/O tokens cannot be slices")
        else
            @intFromPtr(token),
        .optional => |o| switch (@typeInfo(o.child)) {
            .pointer => if (token) |ptr| token_to_u64(ptr) else 0,
            else => @compileError("optional I/O tokens must be pointers"),
        },
        .int => |i| if (i.bits <= 64)
            @as(std.meta.Int(.unsigned, i.bits), @bitCast(token))
        else
            @compileError("I/O integer tokens must fit in 64 bits"),
        .@"enum" => token_to_u64(@intFromEnum(token)),
        .bool => @intFromBool(token),
        else => @compileError("I/O tokens must be pointers, integers, enums or bools"),
    };
}

fn token_from_u64(comptime T: type, value: u64) T {
    return switch (@typeInfo(T)) {
        .pointer => |p| if (p.size == .slice)
            @compileError("I/O tokens cannot be slices")
        else
            @ptrFromInt(@as(usize, @intCast(value))),
        .optional => |o| switch (@typeInfo(o.child)) {
            .pointer => if (value == 0) null else token_from_u64(o.child, value),
            else => @compileError("optional I/O tokens must be pointers"),
        },
        .int => |i| if (i.bits <= 64)
            @bitCast(@as(std.meta.Int(.unsigned, i.bits), @intCast(value)))
        else
            @compileError("I/O integer tokens must fit in 64 bits"),
        .@"enum" => |e| @enumFromInt(token_from_u64(e.tag_type, value)),
        .bool => value != 0,
        else => @compileError("I/O tokens must be pointers, integers, enums or bools"),
    };
}

pub fn Completion(T: type) type {
    return struct {
        res: isize,
        token: T,
    };
}

pub const FileEngine = union(enum) {
    Async: FileEngineAsync,
    Sync: FileEngineSync,

    const Self = @This();

    pub fn ack_event(self: *Self) !void {
        switch (self.*) {
            .Async => |*engine| try engine.ack_event(),
            .Sync => @panic("invalid call"),
        }
    }

    pub fn event_source(self: *const Self) ?std.posix.fd_t {
        return switch (self.*) {
            .Async => |*engine| engine.event.as_fd(),
            .Sync => null,
        };
    }

    pub fn new_async(num_entries: u16) !Self {
        return .{ .Async = try FileEngineAsync.new(num_entries) };
    }

    pub fn deinit(self: *Self) void {
        switch (self.*) {
            inline else => |*engine| engine.deinit(),
        }
    }

    pub fn pop_completion(self: *Self, T: type) !?Completion(T) {
        return switch (self.*) {
            .Async => |*engine| engine.pop_completion(T),
            .Sync => @panic("invalid call"),
        };
    }

    pub fn submit(self: *Self) !void {
        return switch (self.*) {
            .Async => |*engine| engine.submit(),
            .Sync => {},
        };
    }

    pub fn read(self: *Self, fd: posix.fd_t, to: []u8, offset: usize, context: anytype) !?usize {
        return switch (self.*) {
            .Async => |*engine| blk: {
                try engine.register_read(fd, to, offset, context);
                break :blk null;
            },
            .Sync => |*engine| try engine.read(fd, to, offset),
        };
    }

    pub fn write(
        self: *Self,
        fd: posix.fd_t,
        from: []const u8,
        offset: usize,
        context: anytype,
    ) !?usize {
        return switch (self.*) {
            .Async => |*engine| blk: {
                try engine.register_write(fd, from, offset, context);
                break :blk null;
            },
            .Sync => |*engine| try engine.write(fd, from, offset),
        };
    }
};

pub const FileEngineSync = struct {
    const Self = @This();

    pub fn new() !Self {
        return .{};
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn write(self: *Self, fd: posix.fd_t, from: []const u8, offset: usize) !usize {
        _ = self;

        const res = std.os.linux.pwrite(fd, from.ptr, from.len, @intCast(offset));

        return switch (linux.errno(res)) {
            .SUCCESS => res,
            else => error.FailedToWrite,
        };
    }

    pub fn read(self: *Self, fd: posix.fd_t, to: []u8, offset: usize) !usize {
        _ = self;

        const res = std.os.linux.pread(fd, to.ptr, to.len, @intCast(offset));

        return switch (linux.errno(res)) {
            .SUCCESS => res,
            else => error.FailedToRead,
        };
    }
};

pub const FileEngineAsync = struct {
    uring: linux.IoUring,
    event: EventFd,

    const Self = @This();

    pub fn new(num_entries: u16) !Self {
        var uring = try linux.IoUring.init(num_entries, 0);
        errdefer uring.deinit();

        var event = try EventFd.new(0);
        errdefer event.deinit();

        try uring.register_eventfd(event.fd);

        return .{
            .uring = uring,
            .event = event,
        };
    }

    pub fn register_read(self: *Self, fd: posix.fd_t, to: []u8, offset: usize, context: anytype) !void {
        var sqe = try self.uring.get_sqe();

        sqe.prep_rw(.READ, fd, @intFromPtr(to.ptr), to.len, offset);
        sqe.user_data = token_to_u64(context);
    }

    pub fn submit(self: *Self) !void {
        const count = try self.uring.submit();

        log.debug("submitted {} entries\n", .{count});
    }

    pub fn register_write(
        self: *Self,
        fd: posix.fd_t,
        from: []const u8,
        offset: usize,
        context: anytype,
    ) !void {
        var sqe = try self.uring.get_sqe();

        sqe.prep_rw(.WRITE, fd, @intFromPtr(from.ptr), from.len, offset);
        sqe.user_data = token_to_u64(context);
    }

    pub fn ack_event(self: *Self) !void {
        _ = try self.event.read();
    }

    pub fn pop_completion(self: *Self, T: type) !?Completion(T) {
        var cqes: [1]linux.io_uring_cqe = undefined;
        const count = try self.uring.copy_cqes(&cqes, 0);

        if (count == 0)
            return null;

        // NOTE: copy_cqes() calls cqe_seen
        return Completion(T){ .res = cqes[0].res, .token = token_from_u64(T, cqes[0].user_data) };
    }

    pub fn deinit(self: *Self) void {
        self.uring.deinit();
        self.event.deinit();
    }
};

test "Sync engine read returns data immediately and handles EOF" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile(io, "test_file", .{ .read = true });
    defer file.close(io);
    try file.writePositionalAll(io, "hello world", 0);

    var engine = FileEngine{ .Sync = try FileEngineSync.new() };
    defer engine.deinit();
    try std.testing.expectEqual(null, engine.event_source());

    var buffer: [32]u8 = @splat(0xaa);
    const count = try engine.read(file.handle, &buffer, 6, &tmp);

    try std.testing.expectEqual(@as(?usize, 5), count);
    try std.testing.expectEqualSlices(u8, "world", buffer[0..5]);
    try std.testing.expectEqual(@as(u8, 0xaa), buffer[5]);
    try std.testing.expectEqual(@as(?usize, 0), try engine.read(file.handle, &buffer, 11, &tmp));
    try std.testing.expectEqual(@as(?usize, 0), try engine.read(file.handle, &buffer, 20, &tmp));
    try engine.submit();
}

test "Sync engine write completes immediately at the requested offset" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile(io, "test_file", .{ .read = true });
    defer file.close(io);
    try file.writePositionalAll(io, "hello world!", 0);

    var engine = FileEngine{ .Sync = try FileEngineSync.new() };
    defer engine.deinit();
    try std.testing.expectEqual(null, engine.event_source());
    try std.testing.expectEqual(@as(?usize, 5), try engine.write(file.handle, "there", 6, &tmp));

    // No submit or completion event is needed to observe the write.
    var buffer: [32]u8 = undefined;
    const count = try file.readPositionalAll(io, &buffer, 0);
    try std.testing.expectEqualSlices(u8, "hello there!", buffer[0..count]);
    try engine.submit();
}

test "Sync engine propagates read and write errors" {
    var engine = FileEngine{ .Sync = try FileEngineSync.new() };
    defer engine.deinit();

    var buffer: [1]u8 = undefined;
    try std.testing.expectError(error.FailedToRead, engine.read(-1, &buffer, 0, @as(usize, 0)));
    try std.testing.expectError(error.FailedToWrite, engine.write(-1, "x", 0, @as(usize, 0)));
}

fn wait_for_test_event(engine: *FileEngine) !void {
    var epoll = try @import("utils").Epoll.Epoll.new();
    defer epoll.deinit();
    try epoll.add(engine.event_source().?, 0);

    var events: [1]linux.epoll_event = undefined;
    const ready = try epoll.wait(&events, 1000);

    try std.testing.expectEqual(@as(usize, 1), ready.len);
    try std.testing.expect(ready[0].events & linux.EPOLL.IN != 0);
    try engine.ack_event();
}

test "Basic read completion" {
    var buffer: [100]u8 = undefined;
    const message = "hello world";

    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile(io, "test_file", .{ .read = true });
    defer file.close(io);
    try file.writePositionalAll(io, message, 0);

    var engine = try FileEngine.new_async(32);
    defer engine.deinit();

    try std.testing.expectEqual(null, try engine.pop_completion(@TypeOf(&tmp)));
    try std.testing.expectEqual(try engine.read(file.handle, &buffer, 0, &tmp), null);
    try engine.submit();

    try wait_for_test_event(&engine);
    const comp = (try engine.pop_completion(@TypeOf(&tmp))) orelse return error.MissingCompletion;

    try std.testing.expectEqual(&tmp, comp.token);
    try std.testing.expectEqual(@as(isize, message.len), comp.res);
    try std.testing.expectEqualSlices(u8, message, buffer[0..message.len]);

    try std.testing.expectEqual(null, try engine.pop_completion(@TypeOf(&tmp)));
    try std.testing.expectError(error.WouldBlock, engine.ack_event());
}

test "Basic write completion" {
    var buffer: [100]u8 = undefined;
    const message = "hello world";

    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile(io, "test_file", .{ .read = true });
    defer file.close(io);

    var engine = try FileEngine.new_async(32);
    defer engine.deinit();

    try std.testing.expectEqual(null, try engine.pop_completion(@TypeOf(&tmp)));
    try std.testing.expectEqual(null, try engine.write(file.handle, message, 0, &tmp));
    try engine.submit();

    try wait_for_test_event(&engine);
    const comp = (try engine.pop_completion(@TypeOf(&tmp))) orelse return error.MissingCompletion;

    try std.testing.expectEqual(&tmp, comp.token);
    try std.testing.expectEqual(@as(isize, message.len), comp.res);

    const res = try file.readPositionalAll(io, &buffer, 0);
    try std.testing.expectEqualSlices(u8, message, buffer[0..res]);

    try std.testing.expectEqual(null, try engine.pop_completion(@TypeOf(&tmp)));
    try std.testing.expectError(error.WouldBlock, engine.ack_event());
}
