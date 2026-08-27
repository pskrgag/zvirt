//! x86 RTC

pub const Register = enum(u16) {
    Seconds = 0,
    SecondsAlarm = 1,
    Minutes = 2,
    MinutesAlarm = 3,
    Hours = 4,
    HoursAlarm = 5,
    DayWeek = 6,
    DayMonth = 7,
    Month = 8,
    Year = 9,
    StatusA = 10,
    StatusB = 11,
    StatusC = 12,
};

const StatusA = packed struct(u8) {
    rate: u4 = 0b110,
    divider: u3 = 0b10,
    update: u1 = 0,
};

const StatusB = packed struct(u8) {
    daylight: u1 = 0,
    human: u1 = 1, // 24-hour mode
    date_mode: u1 = 1, // binary mode
    square_wave: u1 = 0,
    en_update_end_irq: u1 = 0,
    en_alarm_irq: u1 = 0,
    en_periodic_irq: u1 = 0,
    en_cycle_update: u1 = 0,
};

const StatusC = packed struct(u8) {
    _unused: u4 = 0x0,
    update_end_irq: u1 = 0x0,
    alarm_irq: u1 = 0x0,
    periodic_irq: u1 = 0x0,
    irq_req_flag: u1 = 0x0,
};

pub const Rtc = struct {
    regs: [10]u8 = [_]u8{0} ** 10,
    statusa: StatusA = .{},
    statusb: StatusB = .{},
    statusc: StatusC = .{},

    const Self = @This();

    pub fn write_reg(self: *Self, reg: Register, data: u8) void {
        if (@intFromEnum(reg) <= @intFromEnum(Register.Year)) {
            self.regs[@intFromEnum(reg)] = data;
        }

        if (reg == .StatusA) {
            self.statusa = @bitCast(data);
        }

        if (reg == .StatusB) {
            self.statusb = @bitCast(data);
        }

        if (reg == .StatusC) {
            self.statusc = @bitCast(data);
        }
    }

    pub fn read_reg(self: *Self, reg: Register) u8 {
        if (@intFromEnum(reg) <= @intFromEnum(Register.Year)) {
            return self.regs[@intFromEnum(reg)];
        }

        if (reg == .StatusA) {
            return @bitCast(self.statusa);
        }

        if (reg == .StatusB) {
            return @bitCast(self.statusb);
        }

        if (reg == .StatusC) {
            return @bitCast(self.statusc);
        }

        @panic("todo");
    }
};
