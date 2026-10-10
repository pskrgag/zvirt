//! Snapshot tests

const std = @import("std");
const test_utils = @import("test_utils");
const Vm = @import("../root.zig").Vm;
const Snapshot = @import("root.zig").Snapshot;

const Checkpoint = struct {
    vm: *Vm,
    reached: std.Io.Event = .unset,

    fn guest_exit(ctx: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.reached.set(self.vm.io);

        // Park at the first checkpoint until snapshot() requests a stop.
        // Otherwise the guest can finish all ten iterations before the host wakes.
        while (!self.vm.vcpus[0].?.stop_flag.load(.monotonic)) {
            std.atomic.spinLoopHint();
        }
    }
};

fn test_snapshot_restore(serialized: bool) !void {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    const binary_bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "test_bins/snapshot.bin",
        allocator,
        .unlimited,
    );
    defer allocator.free(binary_bytes);

    var snap = snapshot: {
        const vm = try Vm.new(.{
            .ram_size = 0x20000,
            .binary = binary_bytes,
        }, io, allocator);
        defer vm.deinit(allocator, io);

        var checkpoint = Checkpoint{ .vm = vm };
        vm.archvm.device_bus.io_bus.register_debug_port_cb(&checkpoint, Checkpoint.guest_exit);

        const thread = try std.Thread.spawn(.{}, Vm.run, .{ vm, io });
        defer {
            vm.stop() catch {};
            thread.join();
        }

        try checkpoint.reached.waitTimeout(io, .{
            .duration = .{ .raw = .fromSeconds(10), .clock = .awake },
        });
        break :snapshot try vm.snapshot(io, allocator);
    };
    defer snap.deinit(allocator);

    if (serialized) {
        var tmp_dir = std.testing.tmpDir(.{});
        defer tmp_dir.cleanup();

        const file = try tmp_dir.dir.createFile(io, "vm_snap.bin", .{
            .read = true,
            .exclusive = true,
        });
        defer file.close(io);

        var buffer: [4096]u8 = undefined;
        var writer = file.writer(io, &buffer);
        try snap.serialize_to(&writer.interface);
        try writer.interface.flush();

        var reader = file.reader(io, &buffer);
        var decoded = try Snapshot.serialize_from(&reader.interface, allocator);
        errdefer decoded.deinit(allocator);

        try std.testing.expectEqual(snap.mem_state.ram_size, decoded.mem_state.ram_size);
        try std.testing.expectEqualDeep(snap.snapshoted_cpus(), decoded.snapshoted_cpus());
        try std.testing.expectEqualDeep(snap.snapshoted_memory(), decoded.snapshoted_memory());

        snap.deinit(allocator);
        snap = decoded;
    }

    const cpus = snap.snapshoted_cpus();
    try std.testing.expectEqual(@as(usize, 1), cpus.len);
    try std.testing.expectEqual(@as(u64, 9), cpus[0].regs.rcx);
    try std.testing.expectEqual(@as(u64, 10), cpus[0].regs.rax);

    var output = try test_utils.TmpUartOutput.create();
    defer output.deinit();

    // The original VM is gone; the snapshot owns the RAM needed for restore.
    const restored = try Vm.from_snapshot(snap, allocator, io);
    defer restored.deinit(allocator, io);

    const restored_cpu = try restored.vcpus[0].?.snapshot();
    try std.testing.expectEqualDeep(cpus[0], restored_cpu);

    try restored.attach_console(.{
        .index = 0,
        .output = output.file,
    });

    const thread = try std.Thread.spawn(.{}, Vm.run, .{ restored, io });
    defer {
        restored.stop() catch {};
        thread.join();
    }

    // Resume the remaining iterations and check the guest's success byte.
    const deadline = std.Io.Clock.awake.now(io).addDuration(.fromSeconds(10));
    var buffer: [16]u8 = undefined;

    while (std.Io.Clock.awake.now(io).nanoseconds < deadline.nanoseconds) {
        const contents = try output.read(&buffer);
        if (contents.len != 0) {
            try std.testing.expectEqualStrings("1", contents);
            return;
        }

        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }

    return error.Timeout;
}

test "Snapshot cpu and ram state" {
    try test_snapshot_restore(false);
}

test "Snapshot serialize cpu + ram" {
    try test_snapshot_restore(true);
}

test "Snapshot owns memory" {
    const allocator = std.testing.allocator;
    var snap = Snapshot{};
    defer snap.deinit(allocator);

    var source = [_]u8{ 1, 2, 3, 4 };
    try snap.snapshot_memory(0x1000, &source, allocator);
    @memset(&source, 0);

    const entries = snap.snapshoted_memory();
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqual(@as(u64, 0x1000), entries[0].start);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, entries[0].memory);
}

test "Snapshot memory allocation failure preserves existing entries" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    const allocator = failing.allocator();
    var snap = Snapshot{};
    defer snap.deinit(allocator);

    try snap.snapshot_memory(0x1000, &.{ 1, 2 }, allocator);
    try std.testing.expectError(error.OutOfMemory, snap.snapshot_memory(0x2000, &.{ 3, 4 }, allocator));
    try std.testing.expectEqual(@as(usize, 1), snap.snapshoted_memory().len);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, snap.snapshoted_memory()[0].memory);
}
