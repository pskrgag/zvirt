//! Virtual UART

const std = @import("std");
const File = std.Io.File;
const Io = std.Io;
const Vm = @import("../root.zig").Vm;

pub const Register = enum(u16) {
    Zero = 0,
    One = 1,
    Two = 2,
    Three = 3,
    Four = 4,
    Five = 5,
    Six = 6,
    Seven = 7,
};

const ReadRegister = enum {
    Dll,
    Dlh,
    Rbr,
    Ier,
    Iir,
    Lcr,
    Mcr,
    Lsr,
    Scr,
    Msr,
};

const WriteRegister = enum {
    Dll,
    Thr,
    Ier,
    Fcr,
    Lcr,
    Mcr,
    Dlh,
    Scr,
    Lsr,
};

// Line control register
const Lcr = packed struct(u8) {
    word_length: u2 = 0b11,
    stop_bits: u1 = 0,
    parity: u1 = 0,
    even_parity: u1 = 0,
    sticky_parity: u1 = 0,
    break_control: u1 = 0,
    dlap: u1 = 0,
};

// Line status register
const Lsr = packed struct(u8) {
    data_ready: u1 = 0,
    overrun: u1 = 0,
    parity_error: u1 = 0,
    framing_error: u1 = 0,
    break_irq: u1 = 0,

    // THR and TE are always set, since current impl is synchronous.
    thre: u1 = 1,
    transmitter_empty: u1 = 1,
    fifo_error: u1 = 0,
};

// Interrupt enable register
const Ier = packed struct(u8) {
    receive_irq: u1 = 0,
    thre: u1 = 0,
    recieve_line: u1 = 0,
    modem_status: u1 = 0,
    _unused: u4 = 0,
};

const Irq = enum(u2) {
    None = 0b00,
    ReceiveLine = 0b11,
    ReceiveData = 0b10,
    TransmitterEmpty = 0b01,
};

// Interrupt identification register
//
// Receive line > receive data ready > transmitter empty > modem status
const Iir = packed struct(u8) {
    irq_not_pending: u1 = 1,
    irq: Irq = .None,
    fifo: u1 = 0,
    _unused: u2 = 0,
    fifo_reg_set: u2 = 0,
};

pub const Uart = struct {
    file: File,
    lcr: Lcr = .{},
    scr: u8 = 0,
    mcr: u8 = 0,
    ier: Ier = .{},
    dll: u8 = 1,
    dlh: u8 = 0,
    lsr: Lsr = .{},
    iir: Iir = .{},
    thre_pending: bool = false,

    const Self = @This();

    fn write_byte(self: *Self, data: u8, io: Io) !void {
        const arr = [_]u8{data};
        try self.file.writeStreamingAll(io, &arr);
    }

    fn dlap(self: *const Self) bool {
        return self.lcr.dlap != 0;
    }

    fn irq_enabled(self: *const Self) bool {
        return self.ier.thre != 0;
    }

    fn get_read_register(self: *const Self, reg: Register) ReadRegister {
        return switch (reg) {
            .Zero => if (self.dlap()) .Dll else .Rbr,
            .One => if (self.dlap()) .Dlh else .Ier,
            .Two => .Iir,
            .Three => .Lcr,
            .Four => .Mcr,
            .Five => .Lsr,
            .Seven => .Scr,
            .Six => .Msr,
        };
    }

    fn get_write_register(self: *const Self, reg: Register) !WriteRegister {
        return switch (reg) {
            .Zero => if (self.dlap()) .Dll else .Thr,
            .One => if (self.dlap()) .Dlh else .Ier,
            .Two => .Fcr,
            .Three => .Lcr,
            .Four => .Mcr,
            .Five => if (self.dlap()) .Lsr else error.InvalidWrite,
            .Seven => .Scr,
            else => @panic("todo"),
        };
    }

    fn set_irq(self: *Self, irq: Irq, vm: *Vm) !void {
        if (self.irq_enabled()) {
            self.iir.irq_not_pending = 0;
            self.iir.irq = irq;
            try vm.irq_set(4, true);
        }
    }

    fn clear_irq(self: *Self, vm: *Vm) !void {
        self.iir.irq = .None;
        self.iir.irq_not_pending = 1;
        try vm.irq_set(4, false);
    }

    fn write_reg_interal(self: *Self, reg: WriteRegister, data: u8, vm: *Vm, io: Io) !void {
        // if (reg != .Thr)
        //     std.debug.print("write {} {}\n", .{ reg, data });

        switch (reg) {
            .Thr => {
                try self.write_byte(data, io);
                self.thre_pending = true;
                try self.set_irq(.TransmitterEmpty, vm);
            },
            .Ier => self.ier = @bitCast(data),
            .Fcr => {},
            .Lcr => {
                self.lcr = @bitCast(data);
            },
            .Lsr => {},
            .Mcr => self.mcr = data,
            .Dlh => self.dlh = data,
            .Dll => self.dll = data,
            .Scr => self.scr = data,
        }
    }

    fn read_reg_interal(self: *Self, reg: ReadRegister, vm: *Vm, io: Io) !u8 {
        _ = io;

        // std.debug.print("read {}\n", .{reg});
        return switch (reg) {
            .Rbr => 0x0,
            .Ier => @bitCast(self.ier),
            .Iir => blk: {
                const res: u8 = @bitCast(self.iir);

                if (self.thre_pending) {
                    self.thre_pending = false;
                    try self.clear_irq(vm);
                }

                break :blk res;
            },
            .Lcr => @bitCast(self.lcr),
            .Mcr => self.mcr,
            .Dlh => self.dlh,
            .Dll => self.dll,
            .Scr => self.scr,
            .Lsr => @bitCast(self.lsr),
            .Msr => 0xb0,
        };
    }

    pub fn write_reg(self: *Self, reg: Register, data: u8, vm: *Vm, io: Io) !void {
        const mapped = try self.get_write_register(reg);

        return self.write_reg_interal(mapped, data, vm, io);
    }

    pub fn read_reg(self: *Self, reg: Register, vm: *Vm, io: Io) !u8 {
        const mapped = self.get_read_register(reg);

        return self.read_reg_interal(mapped, vm, io);
    }
};
