//! Virtual UART

const std = @import("std");
const File = std.Io.File;
const Io = std.Io;

pub const Uart = struct {
    file: File,

    const Self = @This();

    pub fn write_bytes(self: *Self, data: []const u8, io: Io) !void {
        try self.file.writeStreamingAll(io, data);
    }
};
