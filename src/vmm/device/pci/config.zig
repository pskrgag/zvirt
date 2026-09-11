//! PCI config space

const std = @import("std");

const TYPE0_VENDOR_OFFSET = 0x0;
const TYPE0_DEVICE_OFFSET = 0x2;
const TYPE0_CLASS_OFFSET = 0xb;
const TYPE0_SUBCLASS_OFFSET = 0xa;

pub const PciClass = enum(u8) {
    Brigde = 0x6,
};

pub const PciConfigSpace = struct {
    pub const SIZE = 256;
    regs: [SIZE]u8,

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
        return self;
    }

    fn validate_type(comptime T: type) void {
        if (T != u8 and T != u16 and T != u32) {
            @compileError("PCI config accesses must use u8, u16, or u32");
        }
    }

    fn validate_access(comptime T: type, offset: usize) Error!void {
        validate_type(T);

        const size = @sizeOf(T);

        if (offset > SIZE or size > SIZE - offset)
            return error.OutOfBounds;

        if (offset % size != 0)
            return error.UnalignedAccess;
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
