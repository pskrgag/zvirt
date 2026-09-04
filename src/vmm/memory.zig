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

    fn contains_range(self: *MemoryRegion, addr: GuestPhysicalAddress, size: usize) bool {
        const start = addr;
        const end = addr + size;

        return start >= self.gpa and end < self.gpa + self.raw.len;
    }

    fn write(self: *MemoryRegion, addr: GuestPhysicalAddress, data: []const u8) ?usize {
        if (!self.contains(addr))
            return null;

        const offset = addr - self.gpa;
        const can_write = @min(self.raw.len - offset, data.len);

        @memcpy(self.raw[offset .. offset + can_write], data[0..can_write]);
        return can_write;
    }
};

pub const GuestMemory = struct {
    regions: std.ArrayList(MemoryRegion),
    slot: u8,

    const Self = @This();

    pub fn new(alloc: Allocator) !*Self {
        const self = try alloc.create(Self);

        self.* = Self{
            .regions = try std.ArrayList(MemoryRegion).initCapacity(alloc, 0),
            .slot = 0,
        };

        return self;
    }

    pub fn add(self: *Self, gpa: GuestPhysicalAddress, mem: []u8, alloc: Allocator) !void {
        const new_slot = self.slot;

        try self.regions.append(alloc, .{ .gpa = gpa, .slot = new_slot, .raw = mem });
        self.slot += 1;
    }

    pub fn deinit(self: *Self, alloc: Allocator) void {
        self.regions.deinit(alloc);
        alloc.destroy(self);
    }

    pub fn as_slice(self: *Self, pa: GuestPhysicalAddress, size: usize) ?[]u8 {
        for (self.regions.items) |*reg| {
            if (reg.contains_range(pa, size)) {
                const offset = pa - reg.gpa;

                return reg.raw[offset .. offset + size];
            }
        }

        return null;
    }

    pub fn write(self: *Self, gpa: GuestPhysicalAddress, data: []const u8) !void {
        var current_gpa = gpa;
        var current_slice = data;

        for (self.regions.items) |*reg| {
            const len = reg.write(current_gpa, current_slice) orelse 0;

            current_gpa += len;
            current_slice = current_slice[len..current_slice.len];
        }

        if (current_slice.len != 0)
            return error.WriteOutOfBounds;
    }
};
