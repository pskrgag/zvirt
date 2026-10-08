//! VMM snapshot

const MAX_VCPUS = @import("../root.zig").MAX_VCPUS;
const vcpu = @import("../vcpu.zig");

const MAX_RAM_ENTRIES = 20;

const VCpusState = struct {
    state: [MAX_VCPUS]vcpu.VCpuState = @splat(undefined),
    count: usize = 0,
};

const MemoryEntry = struct {
    start: u64,
    size: usize,
    memory: []const u8,
};

const DeviceState = struct {
    pci: bool = false,
};

const MemoryState = struct {
    state: [MAX_RAM_ENTRIES]MemoryEntry = @splat(undefined),
    count: usize = 0,
    ram_size: usize = 0,
};

pub const Snapshot = struct {
    cpu_state: VCpusState = .{},
    mem_state: MemoryState = .{},
    device_state: DeviceState = .{},

    const Self = @This();

    pub fn snapshot_cpu(self: *Self, cpu: *vcpu.VCpu) !void {
        if (self.cpu_state.count != cpu.num)
            return error.InvalidOrder;

        self.cpu_state.state[cpu.num] = try cpu.snapshot();
        self.cpu_state.count += 1;
    }

    pub fn snapshot_memory(self: *Self, gpa: u64, mem: []const u8) !void {
        if (self.mem_state.count == MAX_RAM_ENTRIES)
            return error.Overflow;

        for (self.mem_state.state[0..self.mem_state.count]) |i| {
            const other_end = i.start + i.size;
            const self_end = gpa + mem.len;

            if (gpa < other_end and i.start < self_end)
                return error.Overlaps;
        }

        self.mem_state.state[self.mem_state.count] = .{ .start = gpa, .size = mem.len, .memory = mem };
        self.mem_state.count += 1;
    }

    pub fn snapshoted_memory(self: *const Self) []const MemoryEntry {
        return self.mem_state.state[0..self.mem_state.count];
    }

    pub fn snapshoted_cpus(self: *const Self) []const vcpu.VCpuState {
        return self.cpu_state.state[0..self.cpu_state.count];
    }
};
