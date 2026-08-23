//! Helpers shared by integration tests.

const std = @import("std");

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
