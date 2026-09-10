//! Async IO

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const EventFd = @import("utils").EventFd.EventFd;

const log = std.log.scoped(.io_uring);

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

pub const FileEngine = struct {
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

fn wait_for_test_event(engine: *FileEngine) !void {
    var epoll = try @import("utils").Epoll.Epoll.new();
    defer epoll.deinit();
    try epoll.add(engine.event.as_fd(), 0);

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

    var engine = try FileEngine.new(32);
    defer engine.deinit();
    try std.testing.expectEqual(null, try engine.pop_completion(@TypeOf(&tmp)));
    try engine.register_read(file.handle, &buffer, 0, &tmp);
    try engine.submit();

    try wait_for_test_event(&engine);
    const comp = (try engine.pop_completion(@TypeOf(&tmp))) orelse return error.MissingCompletion;

    try std.testing.expectEqual(&tmp, comp.token);
    try std.testing.expectEqual(@as(isize, message.len), comp.res);
    try std.testing.expectEqualSlices(u8, message, buffer[0..message.len]);

    try std.testing.expectEqual(null, try engine.pop_completion(@TypeOf(&tmp)));
    try std.testing.expectError(error.WouldBlock, engine.event.read());
}

test "Basic write completion" {
    var buffer: [100]u8 = undefined;
    const message = "hello world";

    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile(io, "test_file", .{ .read = true });
    defer file.close(io);

    var engine = try FileEngine.new(32);
    defer engine.deinit();
    try std.testing.expectEqual(null, try engine.pop_completion(@TypeOf(&tmp)));
    try engine.register_write(file.handle, message, 0, &tmp);
    try engine.submit();

    try wait_for_test_event(&engine);
    const comp = (try engine.pop_completion(@TypeOf(&tmp))) orelse return error.MissingCompletion;

    try std.testing.expectEqual(&tmp, comp.token);
    try std.testing.expectEqual(@as(isize, message.len), comp.res);

    const res = try file.readPositionalAll(io, &buffer, 0);
    try std.testing.expectEqualSlices(u8, message, buffer[0..res]);

    try std.testing.expectEqual(null, try engine.pop_completion(@TypeOf(&tmp)));
    try std.testing.expectError(error.WouldBlock, engine.event.read());
}
