//! ID allocator

const std = @import("std");

pub fn IdAllocator(comptime Ids: usize) type {
    return struct {
        bitmap: [(Ids / 8) + @intFromBool((Ids % 8) != 0)]u8 = @splat(0),
        count: usize = Ids,

        const Self = @This();

        pub fn allocate(self: *Self) ?usize {
            var res: ?usize = null;

            for (&self.bitmap, 0..) |*map, i| {
                if (~(map.*) == 0)
                    continue;

                const free_bit = @ctz(~(map.*));
                const idx = i * 8 + free_bit;

                if (idx >= self.count)
                    break;

                map.* |= @as(u8, 1) << @truncate(free_bit);
                res = idx;
                break;
            }

            return res;
        }

        pub fn allocate_specific(self: *Self, id: usize) ?usize {
            if (id >= self.count)
                @panic("Out of range ID is requested");

            const index = id / 8;
            const offset = id % 8;

            const bit = @as(u8, 1) << @truncate(offset);

            if (self.bitmap[index] & bit == 0) {
                self.bitmap[index] |= bit;
                return id;
            }

            return null;
        }

        pub fn free(self: *Self, id: usize) void {
            if (id >= self.count)
                @panic("Out of range ID is freed");

            const index = id / 8;
            const offset = id % 8;

            const bit = @as(u8, 1) << @truncate(offset);

            if (self.bitmap[index] & bit == 0)
                @panic("Non-allocated ID is freed");

            self.bitmap[index] &= ~(@as(u8, 1) << @truncate(offset));
        }
    };
}

test {
    var alloc = IdAllocator(10){};

    for (0..10) |i| {
        try std.testing.expectEqual(i, alloc.allocate().?);
    }

    try std.testing.expectEqual(null, alloc.allocate());
    alloc.free(0);
    try std.testing.expectEqual(0, alloc.allocate().?);

    for (0..10) |i| {
        alloc.free(i);
    }

    for (0..10) |i| {
        try std.testing.expectEqual(i, alloc.allocate().?);
    }
}
