//! CMOS

const std = @import("std");
const rtc = @import("mc146818rtc.zig");

pub const Register = enum(u16) {
    In = 0,
    Out = 1,
};

pub const Cmos = struct {
    reg_select: u16 = 0xD,
    rtc: rtc.Rtc = .{},

    const Self = @This();

    pub fn write_reg(self: *Self, reg: Register, data: u8) !void {
        switch (reg) {
            .In => self.reg_select = data & ~(@as(u8, 1) << 7),
            .Out => {
                if (std.enums.fromInt(rtc.Register, self.reg_select)) |rtc_reg| {
                    self.rtc.write_reg(rtc_reg, data);
                    return;
                }

                return error.InvalidWrite;
            },
        }
    }

    pub fn read_reg(self: *Self, reg: Register) u8 {
        return switch (reg) {
            .In => 0xff,
            .Out => blk: {
                if (std.enums.fromInt(rtc.Register, self.reg_select)) |rtc_reg| {
                    break :blk self.rtc.read_reg(rtc_reg);
                } else {
                    std.debug.print("reg {}\n", .{self.reg_select});
                    @panic("todo");
                }
            },
        };
    }
};
