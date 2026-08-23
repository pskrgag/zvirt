//! x86 IO ports

const std = @import("std");
const device = @import("../device/root.zig");
const Io = std.Io;

const Self = @This();

com1: device.uart.Uart = .{
    .file = std.Io.File.stdout(),
},

pub fn handle_io(self: *Self, io_request: anytype, io: std.Io) !void {
    return switch (io_request.port) {
        0x3f8 => self.com1.write_byte(io_request.data.*, io),
        else => {
            std.debug.print("Unknown port {}\n", .{io_request.port});
            return error.UnknowPort;
        },
    };
}
