//! Snapshot tests

const std = @import("std");
const kvm_system = &@import("../root.zig").kvm_system;
const Vm = @import("../root.zig").Vm;
const Snapshot = @import("root.zig").Snapshot;

fn guest_exit(ctx: *anyopaque) void {
    var c: *std.atomic.Value(bool) = @ptrCast(ctx);

    c.store(true, .monotonic);
}

fn vm_run_thread(vm: *Vm, allocator: std.mem.Allocator, io: std.Io) !void {
    _ = allocator;
    try vm.run(io);
}

test "Snapshot cpu state" {
    // const io = std.testing.io;
    // const allocator = std.testing.allocator;
    //
    // const binary_bytes = try std.Io.Dir.cwd().readFileAlloc(
    //     io,
    //     "guest.bin",
    //     allocator,
    //     .unlimited,
    // );
    // defer allocator.free(binary_bytes);
    //
    // var snap: ?Snapshot = null;
    //
    // for (0..10) |_| {
    //     var vm = try Vm.new(.{
    //         .ram_size = 0x20000,
    //         .binary = binary_bytes,
    //     }, io, allocator);
    //     var fired = std.atomic.Value(bool).init(false);
    //
    //     vm.archvm.device_bus.io_bus.register_debug_port_cb(&fired, guest_exit);
    //
    //     const thread = try std.Thread.spawn(.{}, vm_run_thread, .{ vm, allocator, io });
    //
    //     // Wait for guest
    //     while (fired.load(.monotonic) == false) {}
    //
    //     try std.testing.expectEqual(vm.state.state.load(.monotonic), .Running);
    //
    //     snap = try vm.snapshot(io);
    //
    //     thread.join();
    //     vm.deinit(allocator, io);
    // }
}
