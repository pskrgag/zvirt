//! VMM snapshot

const MAX_VCPUS = @import("../root.zig").MAX_VCPUS;
const vcpu = @import("../vcpu.zig");

const MAX_RAM_ENTRIES = 20;

const VCpusState = struct {
    state: [MAX_VCPUS]?vcpu.VCpuState = @splat(null),
};

const RamEntry = struct {
    start: u64,
    size: usize,
    memory: []const u8,
};

const RamState = struct {
    state: [MAX_RAM_ENTRIES]?RamEntry = @splat(null),
    count: usize = 0,
};

pub const Snapshot = struct {
    cpu_state: VCpusState = .{},
    ram: RamState = .{},

    const Self = @This();

    pub fn snapshot_cpu(self: *Self, cpu: *vcpu.VCpu) !void {
        if (self.cpu_state.state[cpu.num] != null)
            return error.AlreadySnapshoted;

        self.cpu_state.state[cpu.num] = try cpu.snapshot();
    }

    pub fn snapshot_ram(self: *Self, gpa: u64, mem: []const u8) !void {
        if (self.ram.count == MAX_RAM_ENTRIES)
            return error.Overflow;

        for (self.ram.state[0..self.ram.count]) |i| {
            const other_end = i.?.start + i.?.size;
            const self_end = gpa + mem.len;

            if (gpa < other_end and i.?.start < self_end)
                return error.Overlaps;
        }

        self.ram.state[self.ram.count] = .{ .start = gpa, .size = mem.len, .memory = mem };
        self.ram.count += 1;
    }
};
