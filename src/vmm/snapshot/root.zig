//! VMM snapshot

const MAX_VCPUS = @import("../root.zig").MAX_VCPUS;
const vcpu = @import("../vcpu.zig");
const std = @import("std");

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

const SnapshotSerializer = struct {
    // File format:
    //
    // Magic: 0xda 0xda 0xda 0xda 0xba
    // Entries[]
    //
    // Entry {
    //     kind: Cpu|Memory|Device|RamSize
    //     size: usize,
    //     data: []u8,
    // }

    const EntryKind = enum(u8) {
        Cpu = 0,
        Memory = 1,
        Device = 2,
        RamSize = 3,
    };

    const CpuEntry = extern struct {
        num: u8,
        state: vcpu.VCpuState,
    };

    const MemEntry = extern struct {
        gpa: u64,
        size: usize,
    };

    const EntryHeader = extern struct {
        kind: u8,
        size: usize,
    };

    const magic: [5]u8 = .{ 0xda, 0xda, 0xda, 0xda, 0xba };

    fn serialize_to(snap: *const Snapshot, writer: *std.Io.Writer) !void {
        try writer.writeAll(&magic);

        const ram_size_header = EntryHeader{
            .kind = @intFromEnum(EntryKind.RamSize),
            .size = @sizeOf(usize),
        };
        try writer.writeAll(std.mem.asBytes(&ram_size_header));
        try writer.writeAll(std.mem.asBytes(&snap.mem_state.ram_size));

        for (0..snap.cpu_state.count) |cpu| {
            const cpu_entry = CpuEntry{
                .num = @truncate(cpu),
                .state = snap.cpu_state.state[cpu],
            };
            const header = EntryHeader{
                .kind = @intFromEnum(EntryKind.Cpu),
                .size = @sizeOf(@TypeOf(cpu_entry)),
            };

            try writer.writeAll(std.mem.asBytes(&header));
            try writer.writeAll(std.mem.asBytes(&cpu_entry));
        }

        for (0..snap.mem_state.count) |ent| {
            const entry = snap.mem_state.state[ent];
            const mem_entry = MemEntry{
                .gpa = entry.start,
                .size = entry.size,
            };
            const header = EntryHeader{
                .kind = @intFromEnum(EntryKind.Memory),
                .size = @sizeOf(@TypeOf(mem_entry)) + entry.memory.len,
            };

            try writer.writeAll(std.mem.asBytes(&header));
            try writer.writeAll(std.mem.asBytes(&mem_entry));
            try writer.writeAll(entry.memory);
        }
    }

    fn serialize_from(reader: *std.Io.Reader, alloc: std.mem.Allocator) !Snapshot {
        var magic_buffer: [5]u8 = undefined;

        try reader.readSliceAll(&magic_buffer);

        if (!std.mem.eql(u8, &magic_buffer, &magic))
            return error.InvalidMagic;

        var snapshot = Snapshot{};
        errdefer snapshot.deinit(alloc);

        while (true) {
            var header: EntryHeader = undefined;
            const read = try reader.readSliceShort(std.mem.asBytes(&header));

            if (read == 0)
                break;

            if (read != @sizeOf(EntryHeader))
                return error.CorruptedInput;

            const kind = std.enums.fromInt(EntryKind, header.kind) orelse {
                return error.CorruptedInput;
            };

            switch (kind) {
                .Cpu => {
                    if (header.size != @sizeOf(CpuEntry)) {
                        return error.CorruptedInput;
                    }

                    var cpu_entry: CpuEntry = undefined;

                    try reader.readSliceAll(std.mem.asBytes(&cpu_entry));

                    try snapshot.snapshot_cpu(cpu_entry.num, cpu_entry.state);
                },
                .Memory => {
                    var memory_entry: MemEntry = undefined;

                    try reader.readSliceAll(std.mem.asBytes(&memory_entry));
                    const bytes = try alloc.alloc(u8, memory_entry.size);
                    defer alloc.free(bytes);

                    try reader.readSliceAll(bytes);
                    try snapshot.snapshot_memory(memory_entry.gpa, bytes, alloc);
                },
                .RamSize => {
                    if (header.size != @sizeOf(usize)) {
                        return error.CorruptedInput;
                    }

                    try reader.readSliceAll(std.mem.asBytes(&snapshot.mem_state.ram_size));
                },
                else => @panic("gg"),
            }
        }

        return snapshot;
    }
};

pub const Snapshot = struct {
    cpu_state: VCpusState = .{},
    mem_state: MemoryState = .{},
    device_state: DeviceState = .{},

    const Self = @This();

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        for (self.snapshoted_memory()) |entry| {
            allocator.free(entry.memory);
        }
    }

    pub fn snapshot_cpu(self: *Self, num: usize, state: vcpu.VCpuState) !void {
        if (self.cpu_state.count != num) {
            return error.InvalidOrder;
        }

        if (num >= MAX_VCPUS) {
            return error.Overflow;
        }

        self.cpu_state.state[num] = state;
        self.cpu_state.count += 1;
    }

    pub fn snapshot_memory(
        self: *Self,
        gpa: u64,
        mem: []const u8,
        allocator: std.mem.Allocator,
    ) !void {
        if (self.mem_state.count == MAX_RAM_ENTRIES)
            return error.Overflow;

        for (self.mem_state.state[0..self.mem_state.count]) |i| {
            const other_end = i.start + i.size;
            const self_end = gpa + mem.len;

            if (gpa < other_end and i.start < self_end)
                return error.Overlaps;
        }

        const memory = try allocator.dupe(u8, mem);

        self.mem_state.state[self.mem_state.count] = .{
            .start = gpa,
            .size = memory.len,
            .memory = memory,
        };
        self.mem_state.count += 1;
    }

    pub fn snapshoted_memory(self: *const Self) []const MemoryEntry {
        return self.mem_state.state[0..self.mem_state.count];
    }

    pub fn snapshoted_cpus(self: *const Self) []const vcpu.VCpuState {
        return self.cpu_state.state[0..self.cpu_state.count];
    }

    pub fn serialize_to(self: *const Self, writer: *std.Io.Writer) !void {
        try SnapshotSerializer.serialize_to(self, writer);
    }

    pub fn serialize_from(reader: *std.Io.Reader, alloc: std.mem.Allocator) !Snapshot {
        return try SnapshotSerializer.serialize_from(reader, alloc);
    }
};
