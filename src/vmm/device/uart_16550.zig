//! Virtual UART

const std = @import("std");
const EventFd = utils.EventFd.EventFd;
const utils = @import("utils");
const File = std.Io.File;
const Io = std.Io;
const log = std.log.scoped(.uart_16550);
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
    in: ?File,
    out: File,
    lcr: Lcr = .{},
    scr: u8 = 0,
    mcr: u8 = 0,
    ier: Ier = .{},
    dll: u8 = 1,
    dlh: u8 = 0,
    lsr: Lsr = .{},
    iir: Iir = .{},
    thre_pending: bool = false,
    storage: [4096]u8 = undefined,
    rx_queue: std.Deque(u8) = undefined,
    irq: u32,
    irqfd: EventFd = undefined,
    irq_set: bool = false,

    const Self = @This();

    pub fn init(self: *Self, vm: *Vm) !void {
        self.irqfd = try EventFd.new(0);
        errdefer self.irqfd.deinit();

        try vm.register_irq(&self.irqfd, self.irq);
        self.rx_queue = std.Deque(u8).initBuffer(&self.storage);
    }

    pub fn deinit(self: *Self) void {
        self.irqfd.deinit();
    }

    pub fn handle_event(self: *Self, io: std.Io) !void {
        while (true) {
            var buffer: [1024]u8 = undefined;
            var buffers: [1][]u8 = .{buffer[0..]};

            // Unwrap here, since it this function must not be called if there is no
            // input source
            const read = try self.in.?.readStreaming(io, &buffers);
            try self.push_rx_bytes(buffer[0..read]);

            if (read < 1024)
                break;
        }
    }

    fn push_rx_bytes(self: *Self, bytes: []const u8) !void {
        for (bytes) |byte| {
            self.rx_queue.pushBackBounded(byte) catch @panic("todo");
        }

        if (self.rx_queue.len > 0) {
            self.lsr.data_ready = 1;
            try self.update_irq();
        }
    }

    fn pop_rx_byte(self: *Self) u8 {
        const res = self.rx_queue.popFront() orelse 0;

        if (self.rx_queue.len == 0) {
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
        try self.out.writeStreamingAll(io, &arr);
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
