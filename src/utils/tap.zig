//! Tun-tap helpers

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

const log = std.log.scoped(.tap);

pub const c = @cImport({
    @cInclude("linux/ioctl.h");
    @cInclude("linux/if.h");
    @cInclude("linux/if_tun.h");
    @cInclude("fcntl.h");
});

pub const Tap = struct {
    fd: posix.fd_t,

    const Self = @This();

    pub fn new(name: []const u8, header_size: i32) !Self {
        var c_name: [c.IFNAMSIZ]u8 = @splat(0);

        if (name.len > c.IFNAMSIZ - 1)
            return error.NameTooLong;

        @memcpy(c_name[0..name.len], name);

        const fd = try posix.openat(
            posix.AT.FDCWD,
            "/dev/net/tun",
            .{ .ACCMODE = .RDWR, .CLOEXEC = true },
            0,
        );
        errdefer _ = linux.close(fd);

        const flags = linux.fcntl(fd, c.F_GETFL, 0);
        if (linux.errno(flags) != .SUCCESS) {
            log.err("Failed to get file flags: {}\n", .{linux.errno(flags)});
            return error.F_GETFL;
        }

        const setfl = linux.fcntl(fd, c.F_SETFL, flags | c.O_NONBLOCK);
        if (linux.errno(setfl) != .SUCCESS) {
            log.err("Failed to get file flags: {}\n", .{linux.errno(setfl)});
            return error.F_SETFL;
        }

        var req = std.mem.zeroes(c.ifreq);

        @memcpy(&req.ifr_ifrn.ifrn_name, &c_name);

        // We don't care about packet info (i guess?)
        req.ifr_ifru.ifru_flags = c.IFF_TAP | c.IFF_NO_PI | c.IFF_VNET_HDR;

        var res = linux.ioctl(fd, c.TUNSETIFF, @intFromPtr(&req));
        if (linux.errno(res) != .SUCCESS) {
            log.err("Failed to TUNSETIFF: {}\n", .{linux.errno(res)});
            return error.TUNSETIFF;
        }

        res = linux.ioctl(fd, c.TUNSETVNETHDRSZ, @intFromPtr(&header_size));
        if (linux.errno(res) != .SUCCESS) {
            log.err("Failed to TUNSETVNETHDRSZ: {}\n", .{linux.errno(res)});
            return error.TUNSETVNETHDRSZ;
        }

        return .{ .fd = fd };
    }

    pub fn readv(self: *Self, iovecs: anytype) !usize {
        const res = linux.readv(self.fd, iovecs.ptr, iovecs.len);

        return switch (linux.errno(res)) {
            .SUCCESS => res,
            .AGAIN => 0,
            else => error.Failed,
        };
    }

    pub fn writev(self: *Self, iovecs: anytype) !usize {
        const res = linux.writev(self.fd, iovecs.ptr, iovecs.len);

        return switch (linux.errno(res)) {
            .SUCCESS => res,
            else => error.Failed,
        };
    }

    pub fn read(self: *Self, data: []u8) !usize {
        return try posix.read(self.fd, data);
    }

    pub fn write(self: *Self, data: []const u8) !usize {
        const res = linux.write(self.fd, data.ptr, data.len);

        if (linux.errno(res) != .SUCCESS) {
            log.err("Failed to send packet: {}\n", .{linux.errno(res)});
            return error.WriteFailed;
        }

        return @intCast(res);
    }

    pub fn deinit(self: *Self) void {
        _ = linux.close(self.fd);
    }
};

test "tap" {
    var tap = try Tap.new("net0", 12);
    defer tap.deinit();
}
