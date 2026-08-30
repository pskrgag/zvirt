//! Mmap leak detector

const builtin = @import("builtin");
const std = @import("std");
const posix = std.posix;
const page_size_min = std.heap.page_size_min;
const AutoHashMap = std.AutoHashMap;
const Mutex = std.Io.Mutex;

// NOTE: It would be nice to check vmsize, but it's unreliable, since allocator may allocate arenas.
// This detector only tracks mmap calls from the VMM

const Range = struct {
    begin: usize,
    size: usize,
};
const MmapEntries = AutoHashMap(Range, void);
const Self = @This();

var lock = Mutex.init;
var entries: ?MmapEntries = null;

pub fn mmap(
    ptr: ?[*]align(page_size_min) u8,
    length: usize,
    prot: posix.PROT,
    flags: posix.MAP,
    fd: posix.fd_t,
    offset: u64,
) posix.MMapError![]align(page_size_min) u8 {
    const res = try posix.mmap(ptr, length, prot, flags, fd, offset);

    if (builtin.is_test) {
        if (entries) |*ent| {
            lock.lock(std.testing.io) catch @panic("gg");
            defer lock.unlock(std.testing.io);

            ent.put(Range{ .begin = @intFromPtr(res.ptr), .size = res.len }, {}) catch @panic("gg");
        }
    }

    return res;
}

pub fn munmap(memory: []align(page_size_min) const u8) void {
    posix.munmap(memory);

    if (builtin.is_test) {
        if (entries) |*ent| {
            lock.lock(std.testing.io) catch @panic("gg");
            defer lock.unlock(std.testing.io);

            const res = ent.remove(Range{ .begin = @intFromPtr(memory.ptr), .size = memory.len });
            if (!res) {
                @panic("Invalid munmap. Please use wrapper");
            }
        }
    }
}

pub fn init(alloc: std.mem.Allocator) !void {
    if (!builtin.is_test)
        @panic("Please use only during test");

    std.debug.assert(entries == null);
    entries = MmapEntries.init(alloc);
}

pub fn deinit() !void {
    if (!builtin.is_test)
        @panic("Please use only during test");

    if (entries) |*ent| {
        const len = ent.count();

        ent.deinit();
        entries = null;

        if (len != 0) {
            std.debug.print("Mmap allocations leaked {}\n", .{len});
            return error.MmapLeaked;
        }
    }
}

test "mmap detector works" {
    const allocator = std.testing.allocator;

    {
        try init(allocator);
        try deinit();
    }

    {
        try init(allocator);

        const map = try mmap(
            null,
            1 << 12,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
            -1,
            0,
        );
        munmap(map);

        try deinit();
    }

    {
        try init(allocator);

        _ = try mmap(
            null,
            1 << 12,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
            -1,
            0,
        );

        try std.testing.expectError(error.MmapLeaked, deinit());
    }
}
