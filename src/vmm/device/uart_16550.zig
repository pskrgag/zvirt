//! Virtual UART

const std = @import("std");
const File = std.Io.File;
const Io = std.Io;

pub const Register = enum(u16) {
    Data = 0,
    Ier = 1,
    Iir = 2,
    Lcr = 3,
    Mcr = 4,
    Lsr = 5,
};

pub const Uart = struct {
    file: File,
    ldap: bool = false,

    const Self = @This();

    fn write_byte(self: *Self, data: u8, io: Io) !void {
        const arr = [_]u8{data};
        try self.file.writeStreamingAll(io, &arr);
    }

    pub fn write_reg(self: *Self, reg: Register, data: u8, io: Io) !void {
        switch (reg) {
            .Data => try self.write_byte(data, io),
            .Ier => {}, // Don't care about IRQs for now
            .Iir => {}, // Control of internal FIFOs. Don't care
            .Lcr => self.ldap = data & (1 << 7) != 0,
            .Mcr => {},
            .Lsr => {},
        }
    }

    pub fn read_reg(self: *Self, reg: Register, io: Io) !u8 {
        _ = io;

        return switch (reg) {
            .Data => @panic("todo"),
            .Ier => 0, // No IRQs enabled
            .Iir => 0x1, // No IRQs pending
            .Lcr => @as(u8, @intFromBool(self.ldap)) << 7,
            .Mcr => 0,
            .Lsr => 0x60, // THRE | TEME (no input + ready to write)
        };
    }
};
