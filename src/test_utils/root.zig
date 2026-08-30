//! Helpers shared by integration tests.

const std = @import("std");
const Dir = std.Io.Dir;

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

    pub fn check_leak(self: *const Self, io: std.Io) !void {
        const new = try Self.snapshot(io);

        if (new.count != self.count) {
            std.debug.print("FDLEAK: old {} new {}\n", .{self.count, new.count});
            return error.FdLeaked;
        }
    }
};
