//! x86 IO ports

const std = @import("std");
const device = @import("../../device/root.zig");
const Io = std.Io;
const IoResult = @import("kvm").IoResult;

const Self = @This();

com1: device.uart.Uart = .{
    .file = std.Io.File.stdout(),
},

config_address: u32 = 0,

pub fn handle_io(self: *Self, io_request: anytype, io: std.Io) !?IoResult {
    const data_ptr: [*]u8 = @ptrCast(io_request.data);
    const data_len =
        @as(usize, io_request.size) *
        @as(usize, io_request.count);

    const data = data_ptr[0..data_len];

    return switch (io_request.port) {
        // UART (COM1)
        0x3f8 => {
            if (io_request.dir == .Out) {
                try self.com1.write_bytes(data, io);
                return null;
            } else {
                @panic("todo");
            }
        },
        0x3f9 => {
            if (io_request.dir == .Out) {
                return null;
            } else {
                return null;
            }
        },
        0x3fd => {
            if (io_request.dir == .In and io_request.size == 1) {
                std.mem.writeInt(u16, data_ptr[0..2], 0x20 | 0x40, .little);
                return null;
            } else {
                std.debug.print("{any}\n", .{io_request});
                @panic("todo");
            }
        },
        // PCI (which we don't support yet)
        0xcf8 => {
            if (io_request.dir == .Out and io_request.size == 4) {
                self.config_address = std.mem.readInt(u32, data[0..4], .little);
                return null;
            } else {
                @panic("todo");
            }
        },
        0xcfc...0xcff => {
            if (io_request.dir == .In) {
                std.mem.writeInt(u32, data_ptr[0..4], 0xFFFFFFFF, .little);
                return .Io;
            } else {
                return null;
            }
        },
        else => {
            std.debug.print("Unknown port {}\n", .{io_request.port});
            return error.UnknowPort;
        },
    };
}
