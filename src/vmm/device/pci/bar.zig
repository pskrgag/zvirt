//! PCI BAR address ranges and allocation.

const std = @import("std");
const MmioDevice = @import("../root.zig").MmioDevice;

pub const Bar = struct {
    base: u64,
    size: usize,
    handler: MmioDevice,

    const Self = @This();

    pub const State = struct {
        base: u64,
        size: usize,
    };

    pub fn snapshot(self: *const Self) State {
        return .{ .base = self.base, .size = self.size };
    }

    pub fn from_snapshot(state: *const State, handler: MmioDevice) Self {
        return .{ .base = state.base, .size = state.size, .handler = handler };
    }

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

    pub const State = struct {
        base: u64,
        size: usize,
        offset: usize,
    };

    pub fn from_snapshot(state: *const State) Self {
        return .{ .base = state.base, .size = state.size, .offset = state.offset };
    }

    pub fn snapshot(self: *const Self) State {
        return .{ .offset = self.offset, .size = self.size, .base = self.base };
    }

    pub fn allocate(self: *Self, size: usize, handler: MmioDevice) !Bar {
        if (self.offset + size > self.size)
            return error.NoMemory;

        if (!std.math.isPowerOfTwo(size))
            return error.InvalidSize;

        const res = Bar{
            .base = self.base + self.offset,
            .size = size,
            .handler = handler,
        };

        self.offset += size;
        return res;
    }
};
