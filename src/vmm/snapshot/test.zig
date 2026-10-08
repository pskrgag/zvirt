//! Snapshot tests

const std = @import("std");
const test_utils = @import("test_utils");
const Vm = @import("../root.zig").Vm;

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

test "Snapshot cpu state" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    const binary_bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "test_bins/snapshot.bin",
        allocator,
        .unlimited,
    );
    defer allocator.free(binary_bytes);

    const vm = try Vm.new(.{
        .ram_size = 0x20000,
        .binary = binary_bytes,
    }, io, allocator);
    // Snapshot memory is borrowed, so keep the original VM alive during restore.
    defer vm.deinit(allocator, io);

    var checkpoint = Checkpoint{ .vm = vm };
    vm.archvm.device_bus.io_bus.register_debug_port_cb(&checkpoint, Checkpoint.guest_exit);

    const snap = snapshot: {
        const thread = try std.Thread.spawn(.{}, Vm.run, .{ vm, io });
        defer {
            vm.stop() catch {};
            thread.join();
        }

        try checkpoint.reached.waitTimeout(io, .{
            .duration = .{ .raw = .fromSeconds(10), .clock = .awake },
        });
        break :snapshot try vm.snapshot(io);
    };

    const cpus = snap.snapshoted_cpus();
    try std.testing.expectEqual(@as(usize, 1), cpus.len);
    try std.testing.expectEqual(@as(u64, 9), cpus[0].regs.rcx);
    try std.testing.expectEqual(@as(u64, 10), cpus[0].regs.rax);

    var output = try test_utils.TmpUartOutput.create();
    defer output.deinit();

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
