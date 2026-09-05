//! Test disk utils

const std = @import("std");

const FILE_NAME = "disk.img";

pub const DiskImage = struct {
    tmp: std.testing.TmpDir,
    file: std.Io.File,

    const Self = @This();

    pub fn create(size: usize) !Self {
        const io = std.testing.io;
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();

        const file = try tmp.dir.createFile(io, FILE_NAME, .{
            .read = true,
            .exclusive = true,
        });
        errdefer file.close(io);

        var buffer: [4096]u8 = undefined;
        var offset: usize = 0;

        while (offset < size) {
            const bytes = buffer[0..@min(buffer.len, size - offset)];

            io.random(bytes);
            try file.writePositionalAll(io, bytes, offset);
            offset += bytes.len;
        }

        return .{ .tmp = tmp, .file = file };
    }

    pub fn deinit(self: *Self) void {
        self.file.close(std.testing.io);
        self.tmp.cleanup();
    }

    pub fn path(self: *Self, alloc: std.mem.Allocator) ![:0]const u8 {
        return try self.tmp.dir.realPathFileAlloc(std.testing.io, "disk.img", alloc);
    }
};

test "create disk images with exact requested sizes" {
    const io = std.testing.io;

    for ([_]usize{ 0, 17, 4096, 4097 }) |size| {
        var disk = try DiskImage.create(size);
        defer disk.deinit();

        const stat = try disk.file.stat(io);
        try std.testing.expectEqual(@as(u64, size), stat.size);
        var buffer: [4097]u8 = undefined;
        const read = try disk.file.readPositionalAll(io, &buffer, 0);
        try std.testing.expectEqual(size, read);
    }
}
