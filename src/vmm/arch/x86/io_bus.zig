//! x86 IO ports

const std = @import("std");
const device = @import("../../device/root.zig");
const Io = std.Io;
const IoResult = @import("kvm").IoResult;
const Vm = @import("../../root.zig").Vm;
const VmConfig = @import("../../root.zig").VmConfig;
const VmConsoleConfig = @import("../../root.zig").VmConsoleConfig;
const Mutex = std.Io.Mutex;
const posix = std.posix;
const pci = @import("../../device/pci/root.zig");
const PciBus = pci.PciBus;
const PciBridge = pci.PciBus;
const PciAddress = pci.PciAddress;
const PciDevice = @import("../../device/pci/root.zig").PciDevice;

const log = std.log.scoped(.io_bus);

const Self = @This();

const MAX_COMS: usize = 4;

const AddressPort = packed struct(u32) {
    _reserved: u2 = 0,
    register: u6 = 0,
    function: u3 = 0,
    device: u5 = 0,
    bus: u8 = 0,
    _reserved1: u7 = 0,
    enable: u1 = 0,
};

com_mutex: [MAX_COMS]Mutex = @splat(Mutex.init),
com: [MAX_COMS]?device.uart_16550.Uart = @splat(null),
orig_tcattr: [MAX_COMS]?posix.termios = @splat(null),

pci_bus_obj: ?PciBus = null,
cmos: device.cmos.Cmos = .{},
address_port: AddressPort = std.mem.zeroes(AddressPort),

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

pub fn pci_bus(self: *Self) ?*PciBus {
    if (self.pci_bus_obj) |*obj| {
        return obj;
    } else {
        return null;
    }
}

pub fn attach_pci_device(self: *Self, pci_dev: PciDevice, id: usize) !*PciDevice {
    std.debug.assert(self.pci_bus_obj != null);

    return try self.pci_bus_obj.?.attach(pci_dev, id);
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
    try self.com[index].?.init(vm);

    if (console.input) |in|
        try vm.register_fd(in.handle, @intCast(index), .io_bus);

    if (console.configure_terminal) {
        try self.setup_terminal(console.output.handle, index);
    }
}

pub fn new(config: *const VmConfig) Self {
    var self = Self{};

    if (config.pci)
        self.pci_bus_obj = PciBus.new(pci.PciBridge.new(), config);

    return self;
}

pub fn deinit(self: *Self, alloc: std.mem.Allocator, io: std.Io) void {
    if (self.pci_bus_obj) |*bus|
        bus.deinit(alloc, io);

    // unwrap here, since if self.original exists, then com1 must also exist
    for (self.orig_tcattr, 0..) |orig, i| {
        if (orig) |o|
            posix.tcsetattr(self.com[i].?.out.handle, .NOW, o) catch @panic("failed to restore term");
    }

    for (&self.com) |*com| {
        if (com.*) |*c|
            c.deinit();
    }
}

pub fn handle_event(self: *Self, id: u29, io: std.Io) !void {
    if (id >= MAX_COMS)
        return error.InvalidComIndex;

    const index: usize = @intCast(id);
    try self.com_mutex[index].lock(io);
    defer self.com_mutex[index].unlock(io);

    if (self.com[index]) |*com|
        try com.handle_event(io);
}

fn handle_com(
    self: *Self,
    io_request: anytype,
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
                io,
            );
        } else {
            const res = try com.read_reg(
                std.enums.fromInt(device.uart_16550.Register, offset).?,
                io,
            );

            std.mem.writeInt(u8, data_ptr[0..1], res, .little);
        }
    } else {
        if (io_request.dir == .Out)
            std.mem.writeInt(u8, data_ptr[0..1], 0xff, .little);
    }
}

fn pci_unsupported(data_ptr: [*]u8, io_request: anytype) void {
    for (0..io_request.size) |i| {
        data_ptr[i] = 0xff;
    }
}

pub fn handle_io(self: *Self, io_request: anytype, io: std.Io) !bool {
    const data_ptr: [*]u8 = @ptrCast(io_request.data);
    const data_len =
        @as(usize, io_request.size) *
        @as(usize, io_request.count);

    const data = data_ptr[0..data_len];

    return switch (io_request.port) {
        // UART (COM1)
        0x3f8...0x3ff => {
            try self.handle_com(io_request, 0, io_request.port - 0x3f8, io);
            return false;
        },
        // UART (COM2)
        0x2f8...0x2ff => {
            try self.handle_com(io_request, 1, io_request.port - 0x2f8, io);
            return false;
        },
        // UART (COM3)
        0x3e8...0x3ef => {
            try self.handle_com(io_request, 2, io_request.port - 0x3e8, io);
            return false;
        },
        // UART (COM4)
        0x2e8...0x2ef => {
            try self.handle_com(io_request, 3, io_request.port - 0x2e8, io);
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

        // PCI regs
        0xcf8 => {
            if (self.pci_bus_obj == null) {
                pci_unsupported(data_ptr, io_request);
            } else {
                if (io_request.size != 4) {
                    return error.InvalidWrite;
                }

                if (io_request.dir == .Out) {
                    self.address_port = @bitCast(std.mem.readInt(u32, data_ptr[0..4], .little));
                } else {
                    std.mem.writeInt(u32, data_ptr[0..4], @bitCast(self.address_port), .little);
                }
            }

            return false;
        },

        // This must not happen, since in case of PCI support, linux must stick to 1st method.
        0xcfa => {
            std.debug.assert(self.pci_bus_obj == null);
            pci_unsupported(data_ptr, io_request);

            return false;
        },
        0xcfb => {
            if (io_request.size != 1)
                return error.InvalidWrite;

            if (io_request.dir == .Out) {
                self.address_port.enable = @intCast(std.mem.readInt(u8, data_ptr[0..1], .native) >> 7);
            } else {
                std.mem.writeInt(u8, data_ptr[0..1], @as(u8, self.address_port.enable) << 7, .little);
            }

            return false;
        },

        // For my own sanity:
        //
        // These guys work amazingly stupid.
        //
        // 0xcfc is the first byte of u32
        // 0xcfd is the second byte of u32
        // 0xcfe is the third byte of u32
        // 0xcfd is the forth byte of u32
        //
        // 0xcfc supports 4/2/1 byte read, 0xcfd/0xcfe support 2/1 byte read. 0xcfd supports 1 byte
        // read
        //
        // I don't want to move this shit into PCI level, so PCI always returns u32 and then io_bus
        // returns needed part of the byte
        0xcfc...0xcff => {
            if (self.pci_bus_obj) |*pci_bus_obj| {
                const data_start: u8 = @intCast(io_request.port - 0xcfc);
                const data_end: u8 = data_start + io_request.size;

                if (data_start + io_request.size > 4)
                    return error.InvalidWrite;

                if (io_request.dir == .In) {
                    const register = self.address_port.register;
                    const config_offset: u8 = @as(u8, register) << 2;
                    const reg_data = if (pci_bus_obj.device(self.address_port.device)) |dev|
                        try dev.read_config(config_offset)
                    else
                        0xFFFFFFFF;

                    for (data_start..data_end, 0..) |byte, i| {
                        const shift: u5 = @intCast(byte * 8);

                        data_ptr[i] = @truncate(reg_data >> shift);
                    }
                } else {
                    const register = self.address_port.register;
                    const config_offset: u8 = (@as(u8, register) << 2) + data_start;

                    if (pci_bus_obj.device(self.address_port.device)) |dev| {
                        try dev.write_config(config_offset, data);
                    }
                }
            } else {
                pci_unsupported(data_ptr, io_request);
            }

            return false;
        },
        else => {
            log.err("unknown port access: {any}", .{io_request});
            return error.UnknowPort;
        },
    };
}
