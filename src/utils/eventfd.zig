//! Eventfd helper.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

pub const EventFd = struct {
    fd: posix.fd_t,

    const Self = @This();

    /// Creates a non-blocking, close-on-exec eventfd counter.
    pub fn new(initial_value: u32) !Self {
        return Self.new_with_flags(
            initial_value,
            linux.EFD.CLOEXEC | linux.EFD.NONBLOCK,
        );
    }

    pub fn new_semaphore(initial_value: u32) !Self {
        return Self.new_with_flags(
            initial_value,
            linux.EFD.CLOEXEC | linux.EFD.NONBLOCK | linux.EFD.SEMAPHORE,
        );
    }

    fn new_with_flags(initial_value: u32, flags: u32) !Self {
        const rc = linux.eventfd(initial_value, flags);
        switch (linux.errno(rc)) {
            .SUCCESS => return .{ .fd = @intCast(rc) },
            else => |err| return posix.unexpectedErrno(err),
        }
    }

    pub fn deinit(self: *Self) void {
        const rc = linux.close(self.fd);
        std.debug.assert(linux.errno(rc) == .SUCCESS);
        self.* = undefined;
    }

    pub fn as_fd(self: *const Self) posix.fd_t {
        return self.fd;
    }

    pub fn notify(self: *const Self) !void {
        return self.write(1);
    }

    pub fn write(self: *const Self, value: u64) !void {
        const rc = linux.write(
            self.fd,
            std.mem.asBytes(&value).ptr,
            @sizeOf(u64),
        );
        switch (linux.errno(rc)) {
            .SUCCESS => std.debug.assert(rc == @sizeOf(u64)),
            .AGAIN => return error.WouldBlock,
            .INTR => return error.Interrupted,
            else => |err| return posix.unexpectedErrno(err),
        }
    }

    pub fn read(self: *const Self) !u64 {
        var value: u64 = undefined;
        const rc = linux.read(
            self.fd,
            std.mem.asBytes(&value).ptr,
            @sizeOf(u64),
        );
        switch (linux.errno(rc)) {
            .SUCCESS => {
                std.debug.assert(rc == @sizeOf(u64));
                return value;
            },
            .AGAIN => return error.WouldBlock,
            .INTR => return error.Interrupted,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
};

test "eventfd accumulates notifications" {
    var event_fd = try EventFd.new(0);
    defer event_fd.deinit();

    try event_fd.notify();
    try event_fd.write(2);
    try std.testing.expectEqual(@as(u64, 3), try event_fd.read());
    try std.testing.expectError(error.WouldBlock, event_fd.read());
}

test "eventfd semaphore reads one notification at a time" {
    var event_fd = try EventFd.new_semaphore(2);
    defer event_fd.deinit();

    try std.testing.expectEqual(@as(u64, 1), try event_fd.read());
    try std.testing.expectEqual(@as(u64, 1), try event_fd.read());
    try std.testing.expectError(error.WouldBlock, event_fd.read());
}
