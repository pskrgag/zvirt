//! Epoll helpers.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

pub const Event = linux.epoll_event;
pub const Events = linux.EPOLL;

pub const Epoll = struct {
    fd: posix.fd_t,

    const Self = @This();

    pub fn new() !Self {
        const rc = linux.epoll_create1(linux.EPOLL.CLOEXEC);

        switch (posix.errno(rc)) {
            .SUCCESS => return .{ .fd = @intCast(rc) },
            else => |err| return posix.unexpectedErrno(err),
        }
    }

    pub fn deinit(self: *Self) void {
        const rc = linux.close(self.fd);

        std.debug.assert(posix.errno(rc) == .SUCCESS);
    }

    pub fn add(self: *Self, fd: posix.fd_t, context: u64) !void {
        return self.add_with_events(fd, linux.EPOLL.IN, context);
    }

    pub fn add_with_events(
        self: *Self,
        fd: posix.fd_t,
        events: u32,
        context: u64,
    ) !void {
        return self.control(linux.EPOLL.CTL_ADD, fd, events, context);
    }

    pub fn modify(
        self: *Self,
        fd: posix.fd_t,
        events: u32,
        context: u64,
    ) !void {
        return self.control(linux.EPOLL.CTL_MOD, fd, events, context);
    }

    pub fn remove(self: *Self, fd: posix.fd_t) !void {
        const rc = linux.epoll_ctl(self.fd, linux.EPOLL.CTL_DEL, fd, null);
        switch (posix.errno(rc)) {
            .SUCCESS => {},
            else => |err| return posix.unexpectedErrno(err),
        }
    }

    pub fn pwait(
        self: *Self,
        event_buffer: []Event,
        timeout_ms: i32,
        mask: ?linux.sigset_t,
    ) ![]Event {
        if (event_buffer.len == 0)
            return error.EmptyEventBuffer;

        const max_events: u32 = @intCast(@min(
            event_buffer.len,
            std.math.maxInt(u32),
        ));
        const rc = linux.epoll_pwait(
            self.fd,
            event_buffer.ptr,
            max_events,
            timeout_ms,
            if (mask) |m| &m else null,
        );

        switch (linux.errno(rc)) {
            .SUCCESS => return event_buffer[0..@intCast(rc)],
            .INTR => return error.Interrupted,
            else => |err| return posix.unexpectedErrno(err),
        }
    }

    pub fn wait(
        self: *Self,
        event_buffer: []Event,
        timeout_ms: i32,
    ) ![]Event {
        return self.pwait(event_buffer, timeout_ms, null);
    }

    fn control(
        self: *Self,
        operation: u32,
        fd: posix.fd_t,
        events: u32,
        context: u64,
    ) !void {
        var event: Event = .{
            .events = events,
            .data = .{ .u64 = context },
        };
        const rc = linux.epoll_ctl(self.fd, operation, fd, &event);
        switch (posix.errno(rc)) {
            .SUCCESS => {},
            else => |err| return posix.unexpectedErrno(err),
        }
    }
};

test "epoll reports an eventfd context" {
    var epoll = try Epoll.new();
    defer epoll.deinit();

    const event_fd_rc = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
    switch (posix.errno(event_fd_rc)) {
        .SUCCESS => {},
        else => |err| return posix.unexpectedErrno(err),
    }
    const event_fd: posix.fd_t = @intCast(event_fd_rc);
    defer {
        const rc = linux.close(event_fd);
        std.debug.assert(posix.errno(rc) == .SUCCESS);
    }

    const expected_context = 0x1234_5678_9abc_def0;
    try epoll.add(event_fd, expected_context);

    const value: u64 = 1;
    const write_rc = linux.write(event_fd, std.mem.asBytes(&value).ptr, @sizeOf(u64));
    switch (posix.errno(write_rc)) {
        .SUCCESS => try std.testing.expectEqual(@as(usize, @sizeOf(u64)), write_rc),
        else => |err| return posix.unexpectedErrno(err),
    }

    var event_buffer: [1]Event = undefined;
    const ready = try epoll.wait(&event_buffer, 1000);

    try std.testing.expectEqual(@as(usize, 1), ready.len);
    try std.testing.expect(ready[0].events & linux.EPOLL.IN != 0);
    try std.testing.expectEqual(@as(u64, expected_context), ready[0].data.u64);
}

test "epoll zero timeout returns no events" {
    var epoll = try Epoll.new();
    defer epoll.deinit();

    var event_buffer: [1]Event = undefined;
    const ready = try epoll.wait(&event_buffer, 0);
    try std.testing.expectEqual(@as(usize, 0), ready.len);
}
