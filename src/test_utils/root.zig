//! Helpers shared by integration tests.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const Dir = std.Io.Dir;

pub const mmap = @import("mmap.zig");
pub const DiskImage = @import("disk.zig").DiskImage;

pub const TmpUartOutput = struct {
    tmp: std.testing.TmpDir,
    file: std.Io.File,

    pub fn create() !TmpUartOutput {
        const io = std.testing.io;
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();

        const file = try tmp.dir.createFile(io, "com1.out", .{ .read = true });
        return .{ .tmp = tmp, .file = file };
    }

    pub fn deinit(self: *TmpUartOutput) void {
        self.file.close(std.testing.io);
        self.tmp.cleanup();
    }

    pub fn read(self: *const TmpUartOutput, buffer: []u8) ![]const u8 {
        const len = try self.file.readPositionalAll(std.testing.io, buffer, 0);
        return buffer[0..len];
    }
};

pub const FdLeakDetector = struct {
    count: usize,

    const Self = @This();

    pub fn snapshot(io: std.Io) !Self {
        const dir = try Dir.openDirAbsolute(io, "/proc/self/fd", .{ .iterate = true });

        defer dir.close(io);

        var iterator = dir.iterate();
        var count: usize = 0;

        while (try iterator.next(io)) |entry| {
            _ = entry;
            count += 1;
        }

        // -1 for dir itself
        return .{ .count = count - 1 };
    }

    fn check_leak_ex(self: *const Self, print: bool, io: std.Io) !void {
        const new = try Self.snapshot(io);

        if (new.count != self.count) {
            if (print)
                std.debug.print("FDLEAK: old {} new {}\n", .{ self.count, new.count });
            return error.FdLeaked;
        }
    }

    pub fn check_leak(self: *const Self, io: std.Io) !void {
        const new = try Self.snapshot(io);

        if (new.count != self.count) {
            std.debug.print("FDLEAK: old {} new {}\n", .{ self.count, new.count });
            return error.FdLeaked;
        }
    }
};

test "leak detector works" {
    const io = std.testing.io;

    {
        const snapshot = try FdLeakDetector.snapshot(io);
        try snapshot.check_leak(io);
    }

    {
        const snapshot = try FdLeakDetector.snapshot(io);
        const fd = try posix.openat(
            posix.AT.FDCWD,
            "/dev/null",
            .{
                .ACCMODE = .RDONLY,
            },
            0,
        );
        defer _ = linux.close(fd);

        try std.testing.expectError(error.FdLeaked, snapshot.check_leak_ex(false, io));
    }
}

test {
    _ = @import("mmap.zig");
    _ = @import("disk.zig");
}
