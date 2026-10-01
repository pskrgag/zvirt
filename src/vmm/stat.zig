//! VMM statistics

const std = @import("std");

pub const StatKind = enum(usize) {
    vmexit_io,
    vmexit_mmio,
};

// TODO: make it per-thread to reduce contention.
pub const Statistics = struct {
    counters: [@typeInfo(StatKind).@"enum".fields.len]u64 = @splat(0),

    const Self = @This();

    pub fn new() Self {
        return std.mem.zeroes(Self);
    }

    pub fn read(self: *const Self, comptime stat: StatKind) u64 {
        return @atomicLoad(u64, &self.counters[@intFromEnum(stat)], .monotonic);
    }

    pub fn inc(self: *Self, comptime stat: StatKind) void {
        _ = @atomicRmw(u64, &self.counters[@intFromEnum(stat)], .Add, 1, .monotonic);
    }

    pub fn dec(self: *Self, comptime stat: StatKind) void {
        _ = @atomicRmw(u64, &self.counters[@intFromEnum(stat)], .Sub, 1, .monotonic);
    }

    pub fn add(self: *Self, comptime stat: StatKind, n: u64) void {
        _ = @atomicRmw(u64, &self.counters[@intFromEnum(stat)], .Add, n, .monotonic);
    }
};
