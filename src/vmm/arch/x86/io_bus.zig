//! x86 IO ports

const std = @import("std");
const device = @import("../../device/root.zig");
const Io = std.Io;
const IoResult = @import("kvm").IoResult;

const Self = @This();

com1: device.uart_16550.Uart = .{
    .file = std.Io.File.stdout(),
},

config_address: u32 = 0,
cmos: device.cmos.Cmos = .{},

pub fn handle_io(self: *Self, io_request: anytype, io: std.Io) !?IoResult {
    const data_ptr: [*]u8 = @ptrCast(io_request.data);
    const data_len =
        @as(usize, io_request.size) *
        @as(usize, io_request.count);

    const data = data_ptr[0..data_len];

    return switch (io_request.port) {
        // UART (COM1)
        0x3f8...0x3ff => {
            if (io_request.size != 1)
                return error.InvalidWrite;

            if (io_request.dir == .Out) {
                try self.com1.write_reg(
                    std.enums.fromInt(device.uart_16550.Register, io_request.port - 0x3f8).?,
                    data[0],
                    io,
                );
            } else {
                const res = try self.com1.read_reg(
                    std.enums.fromInt(device.uart_16550.Register, io_request.port - 0x3f8).?,
                    io,
                );

                std.mem.writeInt(u8, data_ptr[0..1], res, .little);
            }

            return null;
        },
        // No COM{2,4}
        0x2f8...0x2ff, 0x3e8...0x3ef, 0x2e8...0x2ef => {
            if (io_request.size != 1)
                return error.InvalidWrite;

            if (io_request.dir == .Out)
                std.mem.writeInt(u8, data_ptr[0..1], 0xff, .little);

            return null;
        },

        0x70...0x71 => {
            if (io_request.size != 1)
                return error.InvalidWrite;

            if (io_request.dir == .Out) {
                try self.cmos.write_reg(
                    std.enums.fromInt(device.cmos.Register, io_request.port - 0x70).?,
                    data[0],
                );
            } else {
                const res = self.cmos.read_reg(
                    std.enums.fromInt(device.cmos.Register, io_request.port - 0x70).?,
                );

                std.mem.writeInt(u8, data_ptr[0..1], res, .little);
            }

            return null;
        },

        // DMA: todo
        0x87 => {
            return null;
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
            std.debug.print("Unknown port {any}\n", .{io_request});
            return error.UnknowPort;
        },
    };
}
