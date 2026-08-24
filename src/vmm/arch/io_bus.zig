//! x86 IO ports

const std = @import("std");
const device = @import("../device/root.zig");
const Io = std.Io;

const Self = @This();

com1: device.uart.Uart = .{
    .file = std.Io.File.stdout(),
},

pub fn handle_io(self: *Self, io_request: anytype, io: std.Io) !void {
    const data_ptr: [*]u8 = @ptrCast(io_request.data);
    const data_len =
        @as(usize, io_request.size) *
        @as(usize, io_request.count);

    const data = data_ptr[0..data_len];

    return switch (io_request.port) {
        0x3f8 => {
            if (io_request.dir == .Out) {
                try self.com1.write_bytes(data, io);
            } else {
                @panic("todo");
            }
        },
        else => {
            std.debug.print("Unknown port {}\n", .{io_request.port});
            return error.UnknowPort;
        },
    };
}
