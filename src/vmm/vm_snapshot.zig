//! VM snapshot state

const std = @import("std");
const SerializableList = @import("snapshot/vector.zig").SerializableList;
const VCpuState = @import("vcpu.zig").VCpuState;
const MAX_VCPUS = @import("root.zig").MAX_VCPUS;
const ArchVmState = @import("root.zig").arch.ArchVm.ArchVmState;

pub const MemoryEntry = struct {
    start: u64,
    memory: []const u8,
};

pub const VmSnapshotState = struct {
    vcpus: SerializableList(VCpuState) = .{},
    memory: SerializableList(MemoryEntry) = .{},
    ram_size: usize = 0,
    arch_state: ArchVmState,

    const Self = @This();

    pub fn new(arch_state: ArchVmState) Self {
        return .{ .arch_state = arch_state };
    }

    pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
        for (self.memory.list.items) |entry| {
            alloc.free(entry.memory);
        }

        self.memory.deinit(alloc);
        self.vcpus.deinit(alloc);
        self.arch_state.deinit(alloc);
    }

    pub fn snapshot_cpu(self: *Self, state: VCpuState, alloc: std.mem.Allocator) !void {
        if (state.num != self.vcpus.list.items.len) {
            return error.InvalidOrder;
        }

        if (self.vcpus.list.items.len >= MAX_VCPUS) {
            return error.Overflow;
        }

        try self.vcpus.list.append(alloc, state);
    }

    pub fn snapshot_memory(
        self: *Self,
        gpa: u64,
        mem: []const u8,
        alloc: std.mem.Allocator,
    ) !void {
        const end = try std.math.add(u64, gpa, mem.len);

        for (self.memory.list.items) |entry| {
            const other_end = try std.math.add(u64, entry.start, entry.memory.len);
            if (gpa < other_end and entry.start < end) {
                return error.Overlaps;
            }
        }

        const bytes = try alloc.dupe(u8, mem);
        errdefer alloc.free(bytes);

        try self.memory.list.append(alloc, .{
            .start = gpa,
            .memory = bytes,
        });
    }

    pub fn snapshoted_cpus(self: *const Self) []const VCpuState {
        return self.vcpus.list.items;
    }

    pub fn snapshoted_memory(self: *const Self) []const MemoryEntry {
        return self.memory.list.items;
    }
};
