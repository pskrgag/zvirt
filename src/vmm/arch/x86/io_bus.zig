//! x86 IO ports

const builtin = @import("builtin");
const std = @import("std");
const device = @import("../../device/root.zig");
const Io = std.Io;
const IoResult = @import("kvm").IoResult;
const Vm = @import("../../root.zig").Vm;
const DeviceConfig = @import("../../root.zig").DeviceConfig;
const VmConsoleConfig = @import("../../root.zig").VmConsoleConfig;
const Mutex = std.Io.Mutex;
const posix = std.posix;
const pci = @import("../../device/pci/root.zig");
const PciBus = pci.PciBus;
const PciBridge = pci.PciBus;
const PciAddress = pci.PciAddress;
const PciDevice = @import("../../device/pci/root.zig").PciDevice;
const Atomic = std.atomic.Value;
const MemorySlot = @import("layout.zig").MemorySlot;

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

const Com = struct {
    mutex: Mutex = .init,
    uart: ?device.uart_16550.Uart = null,
};

pub const State = struct {
    uart: [MAX_COMS]?device.uart_16550.Uart.State = @splat(null),
    pci: bool = false,

    pub fn deinit(self: *State, alloc: std.mem.Allocator) void {
        for (&self.uart) |*entry| {
            if (entry.*) |*uart| {
                uart.deinit(alloc);
            }
        }
    }
};

com: [MAX_COMS]Com = @splat(.{}),

pci_bus_obj: ?*PciBus = null,
cmos: device.cmos.Cmos = .{},
cmos_lock: Mutex = .init,
address_port: Atomic(AddressPort) = .init(std.mem.zeroes(AddressPort)),

debug_cb: ?struct {
    ctx: *anyopaque,
    cb: *const fn (*anyopaque) void,
} = null,

pub fn snapshot(self: *Self, alloc: std.mem.Allocator, io: std.Io) !State {
    var res = State{ .pci = self.pci_bus_obj != null };
    errdefer res.deinit(alloc);

    for (&self.com, 0..) |*port, i| {
        try port.mutex.lock(io);
        defer port.mutex.unlock(io);

        if (port.uart) |*uart| {
            res.uart[i] = try uart.snapshot(alloc);
        }
    }

    return res;
}

pub fn pci_bus(self: *Self) ?*PciBus {
    if (self.pci_bus_obj) |obj| {
        return obj;
    } else {
        return null;
    }
}

pub fn attach_pci_device(self: *Self, pci_dev: PciDevice, id: usize) !*PciDevice {
    std.debug.assert(self.pci_bus_obj != null);

    return try self.pci_bus_obj.?.attach(pci_dev, id);
}

pub fn attach_console(
    self: *Self,
    console: *const VmConsoleConfig,
    vm: *Vm,
    state: ?*const State,
    alloc: std.mem.Allocator,
) !void {
    if (console.index >= MAX_COMS) {
        return error.InvalidComIndex;
    }

    const index: usize = console.index;
    const port = &self.com[index];

    if (port.uart != null) {
        return error.ComAlreadyExists;
    }

    const irq: u32 = if (index == 0 or index == 2)
        4
    else
        3;

    const uart_state = if (state) |snapshot_state|
        if (snapshot_state.uart[index]) |*uart| uart else null
    else
        null;

    port.uart = try device.uart_16550.Uart.new(
        console.output,
        console.input,
        irq,
        vm,
        uart_state,
        console.configure_terminal,
        alloc,
    );
    errdefer {
        port.uart.?.deinit(alloc);
        port.uart = null;
    }

    if (console.input) |in| {
        try vm.register_fd(in.handle, @intCast(index), 0, .io_bus, false);
    }
}

pub fn new(pci_range: ?MemorySlot, alloc: std.mem.Allocator) !Self {
    var self = Self{};

    if (pci_range) |range| {
        self.pci_bus_obj = try PciBus.new(pci.PciBridge.new(), range, alloc);
    }

    return self;
}

pub fn from_snapshot(state: *const State, alloc: std.mem.Allocator, io: std.Io) !Self {
    std.debug.assert(state.pci == false);
    _ = io;

    return Self.new(null, alloc);
}

pub fn deinit(self: *Self, alloc: std.mem.Allocator, io: std.Io) void {
    if (self.pci_bus_obj) |bus| {
        bus.deinit(alloc, io);
    }

    for (&self.com) |*port| {
        if (port.uart) |*uart| {
            uart.deinit(alloc);
        }
    }
}

pub fn handle_event(self: *Self, id: u29, io: std.Io) !void {
    if (id >= MAX_COMS) {
        return error.InvalidComIndex;
    }

    const index: usize = @intCast(id);
    const port = &self.com[index];
    try port.mutex.lock(io);
    defer port.mutex.unlock(io);

    if (port.uart) |*uart| {
        try uart.handle_event(io);
    }
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

    std.debug.assert(idx < self.com.len);

    if (io_request.size != 1) {
        return error.InvalidWrite;
    }

    const port = &self.com[idx];
    try port.mutex.lock(io);
    defer port.mutex.unlock(io);

    if (port.uart == null) {
        return;
    }

    if (port.uart) |*uart| {
        if (io_request.dir == .Out) {
            try uart.write_reg(
                std.enums.fromInt(device.uart_16550.Register, offset).?,
                data[0],
                io,
            );
        } else {
            const res = try uart.read_reg(
                std.enums.fromInt(device.uart_16550.Register, offset).?,
                io,
            );

            std.mem.writeInt(u8, data_ptr[0..1], res, .little);
        }
    } else {
        if (io_request.dir == .Out) {
            std.mem.writeInt(u8, data_ptr[0..1], 0xff, .little);
        }
    }
}

fn pci_unsupported(data_ptr: [*]u8, io_request: anytype) void {
    for (0..io_request.size) |i| {
        data_ptr[i] = 0xff;
    }
}

pub fn register_debug_port_cb(self: *Self, ctx: *anyopaque, cb: *const fn (ctx: *anyopaque) void) void {
    if (builtin.is_test)
        self.debug_cb = .{ .cb = cb, .ctx = ctx };
}

pub fn handle_io(self: *Self, io_request: anytype, io: std.Io) !void {
    const data_ptr: [*]u8 = @ptrCast(io_request.data);
    const data_len =
        @as(usize, io_request.size) *
        @as(usize, io_request.count);

    const data = data_ptr[0..data_len];

    return switch (io_request.port) {
        // UART (COM1)
        0x3f8...0x3ff => {
            try self.handle_com(io_request, 0, io_request.port - 0x3f8, io);
        },
        // UART (COM2)
        0x2f8...0x2ff => {
            try self.handle_com(io_request, 1, io_request.port - 0x2f8, io);
        },
        // UART (COM3)
        0x3e8...0x3ef => {
            try self.handle_com(io_request, 2, io_request.port - 0x3e8, io);
        },
        // UART (COM4)
        0x2e8...0x2ef => {
            try self.handle_com(io_request, 3, io_request.port - 0x2e8, io);
        },
        // Special port to indicate test exit
        0xf4 => {
            if (!builtin.is_test) {
                return;
            }

            if (self.debug_cb) |cb| {
                cb.cb(cb.ctx);
            }
        },
        // No floppy, no POST diagnostics, no PS2
        0x3F0...0x3F7, 0x80, 0x64 => {
            if (io_request.size != 1)
                return error.InvalidWrite;

            if (io_request.dir == .Out)
                std.mem.writeInt(u8, data_ptr[0..1], 0xff, .little);
        },
        0x70...0x71 => {
            if (io_request.size != 1)
                return error.InvalidWrite;

            try self.cmos_lock.lock(io);
            defer self.cmos_lock.unlock(io);

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
        },

        // DMA: todo
        0x87 => {},

        // PCI regs
        0xcf8 => {
            if (self.pci_bus_obj == null) {
                pci_unsupported(data_ptr, io_request);
            } else {
                if (io_request.size != 4) {
                    return error.InvalidWrite;
                }

                if (io_request.dir == .Out) {
                    self.address_port.store(@bitCast(std.mem.readInt(u32, data_ptr[0..4], .little)), .monotonic);
                } else {
                    std.mem.writeInt(u32, data_ptr[0..4], @bitCast(self.address_port.load(.monotonic)), .little);
                }
            }
        },

        // This must not happen, since in case of PCI support, linux must stick to 1st method.
        0xcfa => {
            std.debug.assert(self.pci_bus_obj == null);
            pci_unsupported(data_ptr, io_request);
        },
        0xcfb => {
            if (io_request.size != 1)
                return error.InvalidWrite;

            if (io_request.dir == .Out) {
                var ap = self.address_port.load(.monotonic);

                ap.enable = @intCast(std.mem.readInt(u8, data_ptr[0..1], .native) >> 7);
                self.address_port.store(ap, .monotonic);
            } else {
                const ap = self.address_port.load(.monotonic);

                std.mem.writeInt(u8, data_ptr[0..1], @as(u8, ap.enable) << 7, .little);
            }
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
            if (self.pci_bus_obj) |pci_bus_obj| {
                const data_start: u8 = @intCast(io_request.port - 0xcfc);
                const data_end: u8 = data_start + io_request.size;

                if (data_start + io_request.size > 4)
                    return error.InvalidWrite;

                const ap = self.address_port.load(.monotonic);

                if (io_request.dir == .In) {
                    const register = ap.register;
                    const config_offset: u8 = @as(u8, register) << 2;
                    const reg_data = if (pci_bus_obj.device(ap.device)) |dev|
                        try dev.read_config(config_offset, io)
                    else
                        0xFFFFFFFF;

                    for (data_start..data_end, 0..) |byte, i| {
                        const shift: u5 = @intCast(byte * 8);

                        data_ptr[i] = @truncate(reg_data >> shift);
                    }
                } else {
                    const register = ap.register;
                    const config_offset: u8 = (@as(u8, register) << 2) + data_start;

                    if (pci_bus_obj.device(ap.device)) |dev| {
                        try dev.write_config(config_offset, data, io);
                    }
                }
            } else {
                pci_unsupported(data_ptr, io_request);
            }
        },
        else => {
            log.err("unknown port access: {any}", .{io_request});
            return error.UnknowPort;
        },
    };
}
