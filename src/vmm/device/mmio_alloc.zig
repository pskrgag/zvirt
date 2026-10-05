//! Memory allocator for mmio devices

const std = @import("std");
const mmio_space = @import("../arch/root.zig").layout.mmio_space;

pub const MmioAlloc = struct {
    gpa: u64,

    const Self = @This();

    pub fn new(gpa: u64) Self {
        std.debug.assert(std.mem.isAligned(gpa, 4096));

        return .{ .gpa = gpa };
    }

    pub fn alloc_page(self: *Self) u64 {
        const res = self.gpa;

        self.gpa += 4096;
        return res;
    }
};
