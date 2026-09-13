//! PCI BAR address ranges and allocation.

const std = @import("std");

pub const Bar = struct {
    base: u64,
    size: usize,

    const Self = @This();

    pub fn value(self: *const Self) u32 {
        std.debug.assert(self.base <= std.math.maxInt(u32));
        std.debug.assert(self.base & 0xF == 0);

        // bit 0 -- memory bar
        // bit 2:1 -- 32 bit
        // bit 3 -- not prefetchable
        return @truncate(self.base);
    }
};

pub const BarAllocator = struct {
    base: u64,
    size: usize,
    offset: usize,

    const Self = @This();

    pub fn new(base: u64, size: usize) Self {
        return .{ .base = base, .size = size, .offset = 0 };
    }

    pub fn allocate(self: *Self, size: usize) !Bar {
        if (self.offset + size > self.size)
            return error.NoMemory;

        if (!std.math.isPowerOfTwo(size))
            return error.InvalidSize;

        const res = Bar{ .base = self.base + self.offset, .size = size };

        self.offset += size;
        return res;
    }
};
