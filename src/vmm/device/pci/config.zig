//! PCI config space

const std = @import("std");
const Bar = @import("bar.zig").Bar;

const TYPE0_VENDOR_OFFSET = 0x0;
const TYPE0_DEVICE_OFFSET = 0x2;
const TYPE0_CLASS_OFFSET = 0xb;
const TYPE0_SUBCLASS_OFFSET = 0xa;
const TYPE0_STATUS_OFFSET = 0x6;
const TYPE0_CAP_POINTER_OFFSET = 0x34;

pub const PCI_STATUS_CAP_LIST = 0x10;

const TYPE0_HEADER_SIZE = 64;

fn bar_offset(idx: u8) usize {
    std.debug.assert(idx <= 5);
    return 0x10 + idx * 4;
}

pub const Command = packed struct(u16) {
    io_space: u1,
    memory_space: u1,
    bus_master: u1,
    special_cycles: u1,
    memory_invalidate: u1,
    vga_palette: u1,
    parity_error: u1,
    _reserved: u1,
    serr: u1,
    fast_btb: u1,
    irq_disable: u1,
    _reserved1: u5,
};

pub const PciClass = enum(u8) {
    Brigde = 0x6,
    Storage = 0x1,
};

pub const PciConfigSpace = struct {
    pub const SIZE = 256;

    regs: [SIZE]u8,
    last_offset: ?u8 = null,
    last_size: ?u8 = null,

    const Self = @This();

    pub const Error = error{
        OutOfBounds,
        UnalignedAccess,
    };

    pub fn new_type0(vendor_id: u16, device_id: u16, class: PciClass, subclass: u8) Self {
        var self = Self{ .regs = @splat(0) };

        self.write(u16, TYPE0_VENDOR_OFFSET, vendor_id) catch @panic("");
        self.write(u16, TYPE0_DEVICE_OFFSET, device_id) catch @panic("");
        self.write(u8, TYPE0_CLASS_OFFSET, @intFromEnum(class)) catch @panic("");
        self.write(u8, TYPE0_SUBCLASS_OFFSET, subclass) catch @panic("");
        self.write(u8, TYPE0_CAP_POINTER_OFFSET, TYPE0_HEADER_SIZE) catch @panic("");
        return self;
    }

    pub fn add_capability(self: *Self, bytes: []const u8) !void {
        if (bytes.len >= 256)
            return error.InvalidSize;

        const cur_offset = self.last_offset orelse TYPE0_HEADER_SIZE;
        const cur_size = self.last_size orelse 0;

        self.write(
            u16,
            TYPE0_STATUS_OFFSET,
            try self.read(u8, TYPE0_STATUS_OFFSET) | PCI_STATUS_CAP_LIST,
        ) catch @panic("");

        try self.write_slice(cur_offset + cur_size, bytes);

        if (self.last_offset) |offset| {
            // update cap_next field
            self.write(u8, offset + 1, cur_offset + cur_size) catch @panic("");
        }

        self.last_offset = cur_offset + cur_size;
        self.last_size = @truncate(bytes.len);
    }

    fn validate_type(comptime T: type) void {
        if (T != u8 and T != u16 and T != u32) {
            @compileError("PCI config accesses must use u8, u16, or u32");
        }
    }

    pub fn set_bar(self: *Self, bar_idx: u8, raw: u32) !void {
        if (bar_idx > 5)
            return error.InvalidBar;

        std.debug.print("set bar {x}\n", .{raw});
        self.write(u32, bar_offset(bar_idx), raw) catch @panic("");
    }

    fn validate_size(offset: usize, size: usize) Error!void {
        if (offset > SIZE or size > SIZE - offset)
            return error.OutOfBounds;

        // if (offset % size != 0)
        //     return error.UnalignedAccess;
    }

    fn validate_access(comptime T: type, offset: usize) Error!void {
        validate_type(T);
        try validate_size(offset, @sizeOf(T));
    }

    pub fn read(
        self: *const Self,
        comptime T: type,
        offset: usize,
    ) Error!T {
        try validate_access(T, offset);

        return std.mem.readInt(
            T,
            self.regs[offset..][0..@sizeOf(T)],
            .little,
        );
    }

    pub fn write_slice(
        self: *Self,
        offset: usize,
        data: []const u8,
    ) Error!void {
        const size = data.len;

        try validate_size(offset, size);
        @memcpy(self.regs[offset .. offset + size], data);
    }

    pub fn write(
        self: *Self,
        comptime T: type,
        offset: usize,
        value: T,
    ) Error!void {
        try validate_access(T, offset);

        std.mem.writeInt(
            T,
            self.regs[offset..][0..@sizeOf(T)],
            value,
            .little,
        );
    }
};
