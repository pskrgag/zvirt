//! x86 IO ports

const std = @import("std");
const device = @import("../../device/root.zig");
const Io = std.Io;
const IoResult = @import("kvm").IoResult;
const Vm = @import("../../root.zig").Vm;
const VmConsoleConfig = @import("../../root.zig").VmConsoleConfig;
const Mutex = std.Io.Mutex;
const posix = std.posix;
const log = std.log.scoped(.io_bus);

const Self = @This();

const MAX_COMS: usize = 4;

com_mutex: [MAX_COMS]Mutex = @splat(Mutex.init),
com: [MAX_COMS]?device.uart_16550.Uart = @splat(null),
orig_tcattr: [MAX_COMS]?posix.termios = @splat(null),

config_address: u32 = 0,
cmos: device.cmos.Cmos = .{},

fn setup_terminal(self: *Self, fd: posix.fd_t, idx: usize) !void {
    const original = try posix.tcgetattr(fd);
    var raw = original;

    // Deliver input without waiting for a newline.
    raw.lflag.ICANON = false;

    // Do not echo typed characters.
    raw.lflag.ECHO = false;

    // Keep Ctrl-C, Ctrl-Z, etc. working as signals.
    raw.lflag.ISIG = false;

    // A read may return as soon as one byte is available.
    raw.cc[@intFromEnum(posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(posix.V.TIME)] = 0;

    try posix.tcsetattr(fd, .NOW, raw);

    std.debug.assert(self.orig_tcattr[idx] == null);
    self.orig_tcattr[idx] = original;
}

pub fn attach_console(self: *Self, console: *const VmConsoleConfig, vm: *Vm) !void {
    if (console.index >= MAX_COMS)
        return error.InvalidComIndex;

    const index: usize = console.index;

    if (self.com[index] != null)
        return error.ComAlreadyExists;

    self.com[index] = device.uart_16550.Uart{
        .in = console.input,
        .out = console.output,
        .irq = if (index == 0 or index == 2)
            4
        else
            3,
    };
    self.com[index].?.init();

    if (console.input) |in|
        try vm.register_fd(in.handle, @intCast(index), .io_bus);

    if (console.configure_terminal) {
        try self.setup_terminal(console.output.handle, index);
    }
}

pub fn deinit(self: *Self) void {
    // unwrap here, since if self.original exists, then com1 must also exist
    for (self.orig_tcattr, 0..) |orig, i| {
        if (orig) |o|
            posix.tcsetattr(self.com[i].?.out.handle, .NOW, o) catch @panic("failed to restore term");
    }
}

pub fn handle_event(self: *Self, id: u29, vm: *Vm, io: std.Io) !void {
    if (id >= MAX_COMS)
        return error.InvalidComIndex;

    const index: usize = @intCast(id);
    try self.com_mutex[index].lock(io);
    defer self.com_mutex[index].unlock(io);

    if (self.com[index]) |*com|
        try com.handle_event(vm, io);
}

fn handle_com(
    self: *Self,
    io_request: anytype,
    vm: *Vm,
    idx: usize,
    offset: usize,
    io: std.Io,
) !void {
    const data_ptr: [*]u8 = @ptrCast(io_request.data);
    const data_len =
        @as(usize, io_request.size) *
        @as(usize, io_request.count);

    const data = data_ptr[0..data_len];

    if (io_request.size != 1)
        return error.InvalidWrite;

    if (self.com[idx] == null)
        return;

    try self.com_mutex[idx].lock(io);
    defer self.com_mutex[idx].unlock(io);

    if (self.com[idx]) |*com| {
        if (io_request.dir == .Out) {
            try com.write_reg(
                std.enums.fromInt(device.uart_16550.Register, offset).?,
                data[0],
                vm,
                io,
            );
        } else {
            const res = try com.read_reg(
                std.enums.fromInt(device.uart_16550.Register, offset).?,
                vm,
                io,
            );

            std.mem.writeInt(u8, data_ptr[0..1], res, .little);
        }
    } else {
        if (io_request.dir == .Out)
            std.mem.writeInt(u8, data_ptr[0..1], 0xff, .little);
    }
}

pub fn handle_io(self: *Self, io_request: anytype, vm: *Vm, io: std.Io) !bool {
    const data_ptr: [*]u8 = @ptrCast(io_request.data);
    const data_len =
        @as(usize, io_request.size) *
        @as(usize, io_request.count);

    const data = data_ptr[0..data_len];

    return switch (io_request.port) {
        // UART (COM1)
        0x3f8...0x3ff => {
            try self.handle_com(io_request, vm, 0, io_request.port - 0x3f8, io);
            return false;
        },
        // UART (COM2)
        0x2f8...0x2ff => {
            try self.handle_com(io_request, vm, 1, io_request.port - 0x2f8, io);
            return false;
        },
        // UART (COM3)
        0x3e8...0x3ef => {
            try self.handle_com(io_request, vm, 2, io_request.port - 0x3e8, io);
            return false;
        },
        // UART (COM4)
        0x2e8...0x2ef => {
            try self.handle_com(io_request, vm, 3, io_request.port - 0x2e8, io);
            return false;
        },
        // Special port to indicate test exit
        0xf4 => {
            return true;
        },
        // No floppy, no POST diagnostics, no PS2
        0x3F0...0x3F7, 0x80, 0x64 => {
            if (io_request.size != 1)
                return error.InvalidWrite;

            if (io_request.dir == .Out)
                std.mem.writeInt(u8, data_ptr[0..1], 0xff, .little);

            return false;
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

            return false;
        },

        // DMA: todo
        0x87 => {
            return false;
        },

        // PCI (which we don't support yet)
        0xcf8 => {
            if (io_request.dir == .Out and io_request.size == 4) {
                self.config_address = std.mem.readInt(u32, data[0..4], .little);
                return false;
            } else {
                @panic("todo");
            }
        },
        0xcfc...0xcff => {
            if (io_request.dir == .In) {
                std.mem.writeInt(u32, data_ptr[0..4], 0xFFFFFFFF, .little);
            }

            return false;
        },
        else => {
            log.err("unknown port access: {any}", .{io_request});
            return error.UnknowPort;
        },
    };
}
