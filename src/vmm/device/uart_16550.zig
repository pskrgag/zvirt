//! Virtual UART

const std = @import("std");
const EventFd = utils.EventFd.EventFd;
const utils = @import("utils");
const File = std.Io.File;
const Io = std.Io;
const log = std.log.scoped(.uart_16550);
const Vm = @import("../root.zig").Vm;
const Mutex = std.Io.Mutex;
const CharDev = @import("chardev.zig").CharDev;

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
    chardev: CharDev,
    lcr: Lcr = .{},
    scr: u8 = 0,
    mcr: u8 = 0,
    ier: Ier = .{},
    dll: u8 = 1,
    dlh: u8 = 0,
    lsr: Lsr = .{},
    iir: Iir = .{},
    thre_pending: bool = false,
    irq: u32,
    irqfd: EventFd = undefined,
    irq_set: bool = false,

    pub const State = struct {
        // Store each register as its guest-visible byte, not its packed fields.
        lcr: u8,
        scr: u8,
        mcr: u8,
        ier: u8,
        dll: u8,
        dlh: u8,
        lsr: u8,
        iir: u8,
        thre_pending: bool,
        irq: u32,
        irq_set: bool,
        chardev: CharDev.State,

        pub fn deinit(self: *State, alloc: std.mem.Allocator) void {
            self.chardev.deinit(alloc);
        }
    };

    const Self = @This();

    pub fn new(out: File, in: ?File, irq: u32, vm: *Vm, term: bool, alloc: std.mem.Allocator) !Self {
        var chardev = try CharDev.new(out, in, vm, 1024, term, alloc);
        errdefer chardev.deinit(alloc);

        var irqfd = try EventFd.new(0);
        errdefer irqfd.deinit();

        try vm.register_irq(&irqfd, irq);
        return .{ .chardev = chardev, .irq = irq, .irqfd = irqfd };
    }

    pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
        self.irqfd.deinit();
        self.chardev.deinit(alloc);
    }

    /// The caller must hold the COM lock or otherwise quiesce the UART.
    pub fn snapshot(self: *const Self, alloc: std.mem.Allocator) !State {
        return .{
            .lcr = @bitCast(self.lcr),
            .scr = self.scr,
            .mcr = self.mcr,
            .ier = @bitCast(self.ier),
            .dll = self.dll,
            .dlh = self.dlh,
            .lsr = @bitCast(self.lsr),
            .iir = @bitCast(self.iir),
            .thre_pending = self.thre_pending,
            .irq = self.irq,
            .irq_set = self.irq_set,
            .chardev = try self.chardev.snapshot(alloc),
        };
    }

    pub fn handle_event(self: *Self, io: std.Io) !void {
        try self.chardev.handle_event(io);

        if (!self.chardev.rx_queue_is_empty()) {
            self.lsr.data_ready = 1;
            try self.update_irq();
        }
    }

    fn pop_rx_byte(self: *Self) u8 {
        const res = self.chardev.pop_byte() orelse 0;

        if (self.chardev.rx_queue_is_empty()) {
            self.lsr.data_ready = 0;
        }

        return res;
    }

    fn pending_irq(self: *const Self) ?Irq {
        if (self.lsr.data_ready != 0)
            return .ReceiveData;

        if (self.thre_pending)
            return .TransmitterEmpty;

        return null;
    }

    fn update_irq(self: *Self) !void {
        if (self.pending_irq()) |pending| {
            try self.set_irq(pending);
        } else {
            try self.clear_irq();
        }
    }

    fn write_byte(self: *Self, data: u8, io: Io) !void {
        const arr = [_]u8{data};
        try self.chardev.write(&arr, io);
    }

    fn dlap(self: *const Self) bool {
        return self.lcr.dlap != 0;
    }

    fn irq_enabled(self: *const Self) bool {
        return (self.ier.thre | self.ier.recieve_line | self.ier.receive_irq) != 0;
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

    fn set_irq(self: *Self, irq: Irq) !void {
        if (self.irq_enabled()) {
            self.iir.irq_not_pending = 0;
            self.iir.irq = irq;

            if (!self.irq_set) {
                try self.irqfd.notify();
                self.irq_set = true;
            }
        }
    }

    fn clear_irq(self: *Self) !void {
        self.iir.irq = .None;
        self.iir.irq_not_pending = 1;
        self.irq_set = false;
    }

    fn write_reg_interal(self: *Self, reg: WriteRegister, data: u8, io: Io) !void {
        switch (reg) {
            .Thr => {
                try self.write_byte(data, io);
                self.thre_pending = true;
                try self.update_irq();
            },
            .Ier => {
                self.ier = @bitCast(data);
                try self.update_irq();
            },
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

    fn read_reg_interal(self: *Self, reg: ReadRegister, io: Io) !u8 {
        _ = io;

        return switch (reg) {
            .Rbr => blk: {
                const res = self.pop_rx_byte();

                try self.update_irq();
                break :blk res;
            },
            .Ier => @bitCast(self.ier),
            .Iir => blk: {
                const res: u8 = @bitCast(self.iir);

                if (self.iir.irq == .TransmitterEmpty) {
                    std.debug.assert(self.thre_pending);
                    self.thre_pending = false;

                    try self.update_irq();
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

    pub fn write_reg(self: *Self, reg: Register, data: u8, io: Io) !void {
        const mapped = try self.get_write_register(reg);

        return self.write_reg_interal(mapped, data, io);
    }

    pub fn read_reg(self: *Self, reg: Register, io: Io) !u8 {
        const mapped = self.get_read_register(reg);

        return self.read_reg_interal(mapped, io);
    }
};
