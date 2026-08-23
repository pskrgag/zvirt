//! Virtual UART

const std = @import("std");
const File = std.Io.File;
const Io = std.Io;

pub const Uart = struct {
    file: File,

    const Self = @This();

    pub fn write_byte(self: *Self, byte: u8, io: Io) !void {
        const bytes = [_]u8{byte};

        try self.file.writeStreamingAll(io, &bytes);
    }
};
