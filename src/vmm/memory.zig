//! Guest memory

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const GuestPhysicalAddress = u64;

pub const MemoryRegion = struct {
    raw: []u8,
    gpa: GuestPhysicalAddress,
    slot: u8,

    fn contains(self: *MemoryRegion, addr: GuestPhysicalAddress) bool {
        return addr >= self.gpa and addr < self.gpa + self.raw.len;
    }

    fn write(self: *MemoryRegion, addr: GuestPhysicalAddress, data: []const u8) ?usize {
        if (!self.contains(addr))
            return null;

        const offset = addr - self.gpa;
        const can_write = @min(self.raw.len - offset, data.len);

        @memcpy(self.raw[offset..offset + can_write], data[0..can_write]);
        return can_write;
    }
};

pub const GuestMemory = struct {
    regions: std.ArrayList(MemoryRegion),
    slot: u8,

    const Self = @This();

    pub fn new(alloc: Allocator) !Self {
        return .{
            .regions = try std.ArrayList(MemoryRegion).initCapacity(alloc, 0),
            .slot = 0,
        };
    }

    pub fn allocate(self: *Self, gpa: GuestPhysicalAddress, mem: []u8, alloc: Allocator) !void {
        const new_slot = self.slot;

        try self.regions.append(alloc, .{ .gpa = gpa, .slot = new_slot, .raw = mem });
        self.slot += 1;
    }

    pub fn deinit(self: *Self, alloc: Allocator) void {
        self.regions.deinit(alloc);
    }

    pub fn write(self: *Self, gpa: GuestPhysicalAddress, data: []const u8) !void {
        var written: usize = 0;
        var current_gpa = gpa;
        var current_slice = data;

        for (self.regions.items) |*reg| {
            written += reg.write(current_gpa, current_slice) orelse 0;

            current_gpa += written;
            current_slice = current_slice[written..current_slice.len];
        }

        if (current_slice.len != 0)
            return error.WriteOutOfBounds;
    }
};
