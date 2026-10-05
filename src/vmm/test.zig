//! E2E tests for VMM

const std = @import("std");
const Vm = @import("root.zig").Vm;
const test_utils = @import("test_utils");
const log = std.log.scoped(.vmm_tests);
const posix = std.posix;
const linux = std.os.linux;
const utils = @import("utils");

const kvm_system = &@import("root.zig").kvm_system;

var Called: usize = 0;

fn old_handler(_: std.posix.SIG) callconv(.c) void {
    Called += 1;
}

test "Vm restores sigaction" {
    _ = try kvm_system.get();

    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const binary_bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "test_bins/64bit_guest.bin",
        allocator,
        .unlimited,
    );
    defer allocator.free(binary_bytes);

    const action = std.posix.Sigaction{
        .handler = .{ .handler = @alignCast(&old_handler) },
        .mask = std.posix.sigemptyset(),
        .flags = 0, // no SA_RESTART
    };

    std.posix.sigaction(.USR1, &action, null);

    var vm = try Vm.new(.{
        .ram_size = 0x20000,
        .binary = binary_bytes,
    }, io, allocator);
    vm.deinit(allocator, io);

    _ = std.c.pthread_kill(std.c.pthread_self(), .USR1);
    try std.testing.expectEqual(1, Called);
}

fn vm_run_thread(vm: *Vm, allocator: std.mem.Allocator, io: std.Io) !void {
    _ = allocator;
    try vm.run(io);
}

test "Console attach" {
    _ = try kvm_system.get();

    const io = std.testing.io;
    const allocator = std.testing.allocator;

    {
        const binary_bytes = try std.Io.Dir.cwd().readFileAlloc(
            io,
            "test_bins/64bit_guest.bin",
            allocator,
            .unlimited,
        );
        defer allocator.free(binary_bytes);

        var vm = try Vm.new(.{
            .ram_size = 0x20000,
            .binary = binary_bytes,
        }, io, allocator);
        defer vm.deinit(allocator, io);

        try vm.attach_console(.{
            .index = 0,
            .output = std.Io.File.stdout(),
        });

        if (vm.attach_console(.{
            .index = 0,
            .output = std.Io.File.stdout(),
        })) |_| {
            return error.TestExpectedError;
        } else |_| {}
    }

    {
        const binary_bytes = try std.Io.Dir.cwd().readFileAlloc(
            io,
            "test_bins/64bit_loop.bin",
            allocator,
            .unlimited,
        );
        defer allocator.free(binary_bytes);

        var vm = try Vm.new(.{
            .ram_size = 0x20000,
            .binary = binary_bytes,
        }, io, allocator);
        defer vm.deinit(allocator, io);

        const thread = try std.Thread.spawn(.{}, vm_run_thread, .{ vm, allocator, io });

        // Busy loop until vm starts...
        while (vm.state.state.load(.monotonic) != .Running) {}

        try std.testing.expectError(error.InvalidState, vm.attach_console(.{
            .index = 0,
            .output = std.Io.File.stdout(),
        }));

        try vm.stop();
        thread.join();
    }
}

test "Cannot run vm two times" {
    _ = try kvm_system.get();

    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const binary_bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "test_bins/64bit_guest.bin",
        allocator,
        .unlimited,
    );
    defer allocator.free(binary_bytes);

    var vm = try Vm.new(.{
        .ram_size = 0x20000,
        .binary = binary_bytes,
    }, io, allocator);
    defer vm.deinit(allocator, io);

    try vm.run(io);
    try std.testing.expectError(error.AlreadyStarted, vm.run(io));
}

test "Cannot stop vm two times" {
    _ = try kvm_system.get();

    const io = std.testing.io;
    const allocator = std.testing.allocator;

    {
        const binary_bytes = try std.Io.Dir.cwd().readFileAlloc(
            io,
            "test_bins/64bit_guest.bin",
            allocator,
            .unlimited,
        );
        defer allocator.free(binary_bytes);

        var vm = try Vm.new(.{
            .ram_size = 0x20000,
            .binary = binary_bytes,
        }, io, allocator);
        defer vm.deinit(allocator, io);

        try std.testing.expectError(error.InvalidState, vm.stop());
        try vm.run(io);
        try std.testing.expectError(error.InvalidState, vm.stop());
    }

    {
        const binary_bytes = try std.Io.Dir.cwd().readFileAlloc(
            io,
            "test_bins/64bit_loop.bin",
            allocator,
            .unlimited,
        );
        defer allocator.free(binary_bytes);

        var vm = try Vm.new(.{
            .ram_size = 0x20000,
            .binary = binary_bytes,
        }, io, allocator);
        defer vm.deinit(allocator, io);

        const thread = try std.Thread.spawn(.{}, vm_run_thread, .{ vm, allocator, io });

        // Busy loop until vm starts...
        while (vm.state.state.load(.monotonic) != .Running) {}

        try vm.stop();
        try std.testing.expectError(error.InvalidState, vm.stop());

        thread.join();
    }
}

test "guest port write reaches COM1 UART" {
    _ = try kvm_system.get();

    const io = std.testing.io;
    const allocator = std.testing.allocator;

    try test_utils.mmap.init(allocator);
    defer test_utils.mmap.deinit() catch @panic("mmap leaked");

    const fds = try test_utils.FdLeakDetector.snapshot(io);
    defer fds.check_leak(io) catch @panic("fd leaked");

    const binary_bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "test_bins/64bit_guest.bin",
        allocator,
        .unlimited,
    );
    defer allocator.free(binary_bytes);
    var uart_output = try test_utils.TmpUartOutput.create();
    defer uart_output.deinit();

    var vm = try Vm.new(.{
        .ram_size = 0x20000,
        .binary = binary_bytes,
    }, io, allocator);
    defer vm.deinit(allocator, io);

    try vm.attach_console(.{
        .index = 0,
        .output = uart_output.file,
    });

    try vm.run(io);

    var captured: [16]u8 = undefined;
    try std.testing.expectEqualStrings("H", try uart_output.read(&captured));
}

test "linux reaches shutdown" {
    _ = try kvm_system.get();

    const io = std.testing.io;
    const allocator = std.testing.allocator;

    try test_utils.mmap.init(allocator);
    defer test_utils.mmap.deinit() catch @panic("mmap leaked");

    const fds = try test_utils.FdLeakDetector.snapshot(io);
    defer fds.check_leak(io) catch @panic("fd leaked");

    const binary_bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "test_bins/bzImage",
        allocator,
        .unlimited,
    );
    defer allocator.free(binary_bytes);

    var uart_output = try test_utils.TmpUartOutput.create();
    defer uart_output.deinit();

    var vm = try Vm.new(.{
        .ram_size = 1 << 30,
        .binary = binary_bytes,
    }, io, allocator);
    defer vm.deinit(allocator, io);
    try vm.attach_console(.{
        .index = 0,
        .output = uart_output.file,
    });

    try vm.run(io);
}

fn dump_whole_file(output: *const test_utils.TmpUartOutput) !void {
    var buffer: [128 * 1024]u8 = undefined;
    var reader = output.file.reader(std.testing.io, &buffer);

    while (true) {
        const contents = reader.interface.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => return,
            else => return err,
        };

        log.err("guest console output:\n{s}", .{contents});
        reader.interface.toss(contents.len);
    }
}

const Sha256 = std.crypto.hash.sha2.Sha256;
const disk_sha256_prefix = "DISK-SHA256 ";
const write_test_seed = 0x5a17_c3e2_91bd_704f;
const write_test_size = 256 << 10;

fn hash_file(file: std.Io.File) ![Sha256.digest_length]u8 {
    var hasher = Sha256.init(.{});
    var buffer: [128 * 1024]u8 = undefined;
    var offset: u64 = 0;

    while (true) {
        const bytes_read = try file.readPositionalAll(
            std.testing.io,
            &buffer,
            offset,
        );
        hasher.update(buffer[0..bytes_read]);
        offset += bytes_read;

        if (bytes_read < buffer.len)
            break;
    }

    var digest: [Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

fn expect_file_hash(output: *const test_utils.TmpUartOutput, file: std.Io.File) !void {
    const digest = try hash_file(file);
    const hex = std.fmt.bytesToHex(digest, .lower);
    var expected: [disk_sha256_prefix.len + hex.len + 1]u8 = undefined;

    @memcpy(expected[0..disk_sha256_prefix.len], disk_sha256_prefix);
    @memcpy(expected[disk_sha256_prefix.len..][0..hex.len], &hex);
    expected[expected.len - 1] = '\n';

    var buffer: [128 * 1024]u8 = undefined;
    const contents = try output.read(&buffer);
    try std.testing.expect(std.mem.indexOf(u8, contents, &expected) != null);
}

fn hash_write_pattern(seed: u64, size: u64) [Sha256.digest_length]u8 {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    var hasher = Sha256.init(.{});
    var buffer: [128 * 1024]u8 = undefined;
    var remaining = size;

    while (remaining > 0) {
        const length: usize = @intCast(@min(remaining, buffer.len));
        const bytes = buffer[0..length];

        random.bytes(bytes);
        hasher.update(bytes);
        remaining -= bytes.len;
    }

    var digest: [Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

fn wait_for_output(
    output: *const test_utils.TmpUartOutput,
    needle: []const u8,
) !void {
    const io = std.testing.io;

    const deadline = std.Io.Clock.awake.now(io).addDuration(
        std.Io.Duration.fromSeconds(10),
    );

    var buffer: [128 * 1024]u8 = undefined;

    while (std.Io.Clock.awake.now(io).nanoseconds < deadline.nanoseconds) {
        const contents = try output.read(&buffer);

        if (std.mem.indexOf(u8, contents, needle) != null)
            return;

        try std.Io.sleep(
            io,
            std.Io.Duration.fromMilliseconds(10),
            .awake,
        );
    }

    return error.Timeout;
}

fn login_in_initrd(uart_output: *test_utils.TmpUartOutput, input_writer: *const std.Io.File) !void {
    const io = std.testing.io;

    // Login discards all input data after <enter>. So we need to push data lock-step.
    try wait_for_output(uart_output, "login");
    try input_writer.writeStreamingAll(io, "root\n");

    try wait_for_output(uart_output, "Password:");
    try input_writer.writeStreamingAll(io, "root\n");

    try wait_for_output(uart_output, "# ");
}

test "linux login and reboot" {
    _ = try kvm_system.get();

    const io = std.testing.io;
    const allocator = std.testing.allocator;

    try test_utils.mmap.init(allocator);
    defer test_utils.mmap.deinit() catch @panic("mmap leaked");

    const fds = try test_utils.FdLeakDetector.snapshot(io);
    defer fds.check_leak(io) catch @panic("fd leaked");

    const binary_bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "test_bins/bzImage",
        allocator,
        .unlimited,
    );
    defer allocator.free(binary_bytes);
    const initrd_bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "test_bins/initrd.img",
        allocator,
        .unlimited,
    );
    defer allocator.free(initrd_bytes);

    var uart_output = try test_utils.TmpUartOutput.create();
    defer uart_output.deinit();

    var pipe_fds: [2]posix.fd_t = undefined;
    const pipe_rc = linux.pipe2(&pipe_fds, .{ .CLOEXEC = true });
    switch (posix.errno(pipe_rc)) {
        .SUCCESS => {},
        else => |err| return posix.unexpectedErrno(err),
    }

    const uart_input: std.Io.File = .{
        .handle = pipe_fds[0],
        .flags = .{ .nonblocking = false },
    };
    defer uart_input.close(io);

    const input_writer: std.Io.File = .{
        .handle = pipe_fds[1],
        .flags = .{ .nonblocking = false },
    };
    defer input_writer.close(io);

    var vm = try Vm.new(.{
        .ram_size = 1 << 30,
        .binary = binary_bytes,
        .initramfs = initrd_bytes,
    }, io, allocator);
    defer vm.deinit(allocator, io);

    try vm.attach_console(.{
        .index = 0,
        .input = uart_input,
        .output = uart_output.file,
    });

    const thread = try std.Thread.spawn(.{}, vm_run_thread, .{ vm, allocator, io });

    // Login discards all input data after <enter>. So we need to push data lock-step.
    try login_in_initrd(&uart_output, &input_writer);
    try input_writer.writeStreamingAll(io, "reboot\n");

    thread.join();
}

test "vCPU handles unknown exit reason gracefully" {
    _ = try kvm_system.get();

    const io = std.testing.io;
    const allocator = std.testing.allocator;

    try test_utils.mmap.init(allocator);
    defer test_utils.mmap.deinit() catch @panic("mmap leaked");

    const fds = try test_utils.FdLeakDetector.snapshot(io);
    defer fds.check_leak(io) catch @panic("fd leaked");

    const binary_bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "test_bins/bzImage",
        allocator,
        .unlimited,
    );
    defer allocator.free(binary_bytes);
    const initrd_bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "test_bins/initrd.img",
        allocator,
        .unlimited,
    );
    defer allocator.free(initrd_bytes);

    var uart_output = try test_utils.TmpUartOutput.create();
    defer uart_output.deinit();

    var pipe_fds: [2]posix.fd_t = undefined;
    const pipe_rc = linux.pipe2(&pipe_fds, .{ .CLOEXEC = true });
    switch (posix.errno(pipe_rc)) {
        .SUCCESS => {},
        else => |err| return posix.unexpectedErrno(err),
    }

    const uart_input: std.Io.File = .{
        .handle = pipe_fds[0],
        .flags = .{ .nonblocking = false },
    };
    defer uart_input.close(io);

    const input_writer: std.Io.File = .{
        .handle = pipe_fds[1],
        .flags = .{ .nonblocking = false },
    };
    defer input_writer.close(io);

    var vm = try Vm.new(.{
        .ram_size = 1 << 30,
        .binary = binary_bytes,
        .initramfs = initrd_bytes,

        // use panic=default. In such case kernel will try to use BIOS reset vector, which is
        // unmapped. This access will lead to KVM_INTERNALL_ERROR. VMM must handle it gracefully.
        .cmdline = "panic=default pci=off",
    }, io, allocator);
    defer vm.deinit(allocator, io);

    try vm.attach_console(.{
        .index = 0,
        .input = uart_input,
        .output = uart_output.file,
    });

    const thread = try std.Thread.spawn(.{}, vm_run_thread, .{ vm, allocator, io });
    try login_in_initrd(&uart_output, &input_writer);
    try input_writer.writeStreamingAll(io, "reboot\n");
    thread.join();
}

test "linux reaches console" {
    _ = try kvm_system.get();

    const io = std.testing.io;
    const allocator = std.testing.allocator;

    try test_utils.mmap.init(allocator);
    defer test_utils.mmap.deinit() catch @panic("mmap leaked");

    const fds = try test_utils.FdLeakDetector.snapshot(io);
    defer fds.check_leak(io) catch @panic("fd leaked");

    const binary_bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "test_bins/bzImage",
        allocator,
        .unlimited,
    );
    defer allocator.free(binary_bytes);
    const initrd_bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "test_bins/initrd.img",
        allocator,
        .unlimited,
    );
    defer allocator.free(initrd_bytes);

    var uart_output = try test_utils.TmpUartOutput.create();
    defer uart_output.deinit();

    var vm = try Vm.new(.{
        .ram_size = 1 << 30,
        .binary = binary_bytes,
        .initramfs = initrd_bytes,
    }, io, allocator);
    defer vm.deinit(allocator, io);
    try vm.attach_console(.{
        .index = 0,
        .output = uart_output.file,
    });

    const thread = try std.Thread.spawn(.{}, vm_run_thread, .{ vm, allocator, io });
    try wait_for_output(&uart_output, "login");

    // Stop the vm
    try vm.stop();
    thread.join();
}

fn test_virtio_read(pci: bool, async: bool) !void {
    _ = try kvm_system.get();

    const io = std.testing.io;
    const allocator = std.testing.allocator;

    try test_utils.mmap.init(allocator);
    defer test_utils.mmap.deinit() catch @panic("mmap leaked");

    const fds = try test_utils.FdLeakDetector.snapshot(io);
    defer fds.check_leak(io) catch @panic("fd leaked");

    const binary_bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "test_bins/bzImage",
        allocator,
        .unlimited,
    );
    defer allocator.free(binary_bytes);
    const initrd_bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "zig-out/initrds/test_block.img",
        allocator,
        .unlimited,
    );
    defer allocator.free(initrd_bytes);

    var disk = try test_utils.DiskImage.create(256 << 10);
    defer disk.deinit();

    const disk_path = try disk.path(allocator);
    defer allocator.free(disk_path);

    var uart_output = try test_utils.TmpUartOutput.create();
    defer uart_output.deinit();

    errdefer {
        dump_whole_file(&uart_output) catch {};
    }

    var initrd_stdout = try test_utils.TmpUartOutput.create();
    defer initrd_stdout.deinit();

    var vm = try Vm.new(.{
        .ram_size = 1 << 30,
        .binary = binary_bytes,
        .initramfs = initrd_bytes,
        .device_config = .{
            .block_device = .{ .path = disk_path, .async = async },
            .pci = pci,
        },
    }, io, allocator);
    defer vm.deinit(allocator, io);

    try vm.attach_console(.{
        .index = 0,
        .output = uart_output.file,
    });
    try vm.attach_console(.{
        .index = 1,
        .output = initrd_stdout.file,
    });

    const thread = try std.Thread.spawn(.{}, vm_run_thread, .{ vm, allocator, io });

    try wait_for_output(&uart_output, "END");

    // Stop the vm
    try vm.stop();
    thread.join();

    try expect_file_hash(&initrd_stdout, disk.file);
}

test "Virtio MMIO IO read (async)" {
    try test_virtio_read(false, true);
}

test "Virtio PCI IO read (async)" {
    try test_virtio_read(true, true);
}

test "Virtio MMIO IO read (sync)" {
    try test_virtio_read(false, false);
}

test "Virtio PCI IO read (sync)" {
    try test_virtio_read(true, false);
}

fn test_virtio_write(pci: bool, async: bool, smp: u8) !void {
    _ = try kvm_system.get();

    const io = std.testing.io;
    const allocator = std.testing.allocator;

    try test_utils.mmap.init(allocator);
    defer test_utils.mmap.deinit() catch @panic("mmap leaked");

    const fds = try test_utils.FdLeakDetector.snapshot(io);
    defer fds.check_leak(io) catch @panic("fd leaked");

    const binary_bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "test_bins/bzImage",
        allocator,
        .unlimited,
    );
    defer allocator.free(binary_bytes);
    const initrd_bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "zig-out/initrds/test_block_write.img",
        allocator,
        .unlimited,
    );
    defer allocator.free(initrd_bytes);

    var disk = try test_utils.DiskImage.create(write_test_size);
    defer disk.deinit();

    const disk_path = try disk.path(allocator);
    defer allocator.free(disk_path);

    var uart_output = try test_utils.TmpUartOutput.create();
    defer uart_output.deinit();
    errdefer dump_whole_file(&uart_output) catch {};

    var vm = try Vm.new(.{
        .ram_size = 1 << 30,
        .binary = binary_bytes,
        .initramfs = initrd_bytes,
        .device_config = .{
            .block_device = .{ .path = disk_path, .async = async },
            .pci = pci,
        },
        .smp = smp,
    }, io, allocator);
    defer vm.deinit(allocator, io);

    try vm.attach_console(.{
        .index = 0,
        .output = uart_output.file,
    });

    const thread = try std.Thread.spawn(.{}, vm_run_thread, .{ vm, allocator, io });

    try wait_for_output(&uart_output, "END");

    try vm.stop();
    thread.join();

    const expected = hash_write_pattern(write_test_seed, write_test_size);
    const actual = try hash_file(disk.file);
    try std.testing.expectEqualSlices(u8, &expected, &actual);
}

test "Virtio MMIO IO write (async+up)" {
    try test_virtio_write(false, true, 1);
}

test "Virtio PCI IO write (async+up)" {
    try test_virtio_write(true, true, 1);
}

test "Virtio MMIO IO write (async+smp)" {
    try test_virtio_write(false, true, 8);
}

test "Virtio PCI IO write (async+smp)" {
    try test_virtio_write(true, true, 8);
}

test "Virtio MMIO IO write (sync+up)" {
    try test_virtio_write(false, false, 1);
}

test "Virtio PCI IO write (sync+up)" {
    try test_virtio_write(true, false, 1);
}

test "Virtio MMIO IO write (sync+smp)" {
    try test_virtio_write(false, false, 8);
}

test "Virtio PCI IO write (sync+smp)" {
    try test_virtio_write(true, false, 8);
}

// Keep in sync with Justfile
const TEST_IFACE = "net0";
const TEST_MAC = "aa:aa:aa:aa:aa:aa";
const tcp_test_server =
    \\import socket
    \\with socket.socket() as server:
    \\    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    \\    server.settimeout(10)
    \\    server.bind(("192.0.2.1", 12345))
    \\    server.listen()
    \\    print("tcp-ready", flush=True)
    \\    conn, _ = server.accept()
    \\    with conn:
    \\        conn.settimeout(10)
    \\        print(conn.recv(4096).decode(), flush=True)
    \\        conn.sendall(b"hello from host")
;

fn test_virtio_net(smp: u8, pci: bool) !void {
    _ = try kvm_system.get();

    const io = std.testing.io;
    const allocator = std.testing.allocator;

    try test_utils.mmap.init(allocator);
    defer test_utils.mmap.deinit() catch @panic("mmap leaked");

    var fds = try test_utils.FdLeakDetector.snapshot(io);
    defer fds.check_leak(io) catch @panic("fd leaked");

    const binary_bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "test_bins/bzImage",
        allocator,
        .unlimited,
    );
    defer allocator.free(binary_bytes);
    const initrd_bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "test_bins/initrd.img",
        allocator,
        .unlimited,
    );
    defer allocator.free(initrd_bytes);

    var uart_output = try test_utils.TmpUartOutput.create();
    defer uart_output.deinit();
    errdefer dump_whole_file(&uart_output) catch {};

    var pipe_fds: [2]posix.fd_t = undefined;
    const pipe_rc = linux.pipe2(&pipe_fds, .{ .CLOEXEC = true });
    switch (posix.errno(pipe_rc)) {
        .SUCCESS => {},
        else => |err| return posix.unexpectedErrno(err),
    }

    const uart_input: std.Io.File = .{
        .handle = pipe_fds[0],
        .flags = .{ .nonblocking = false },
    };
    defer uart_input.close(io);

    const input_writer: std.Io.File = .{
        .handle = pipe_fds[1],
        .flags = .{ .nonblocking = false },
    };
    defer input_writer.close(io);

    var vm = try Vm.new(.{
        .ram_size = 1 << 30,
        .binary = binary_bytes,
        .initramfs = initrd_bytes,
        .device_config = .{
            .pci = pci,
            .network = .{ .mac = try utils.Mac.from_str(TEST_MAC), .iface = TEST_IFACE },
        },
        .smp = smp,
    }, io, allocator);
    defer vm.deinit(allocator, io);

    try vm.attach_console(.{
        .index = 0,
        .input = uart_input,
        .output = uart_output.file,
    });

    const thread = try std.Thread.spawn(.{}, vm_run_thread, .{ vm, allocator, io });

    defer {
        vm.stop() catch {};
        thread.join();
    }

    try login_in_initrd(&uart_output, &input_writer);

    try input_writer.writeStreamingAll(io, "ip a\n");
    try wait_for_output(&uart_output, TEST_MAC);

    // Setup the device
    try input_writer.writeStreamingAll(io, "ip addr add 192.0.2.2/24 dev eth0 && echo 'ok'\n");
    try wait_for_output(&uart_output, "ok");

    try input_writer.writeStreamingAll(io, "ip link set eth0 up && echo 'ok1'\n");
    try wait_for_output(&uart_output, "ok1");

    // Test ARP
    try test_utils.run_program(io, &.{ "arping", "-I", TEST_IFACE, "-c", "3", "192.0.2.2" });

    // Test ICMP
    try test_utils.run_program(io, &.{ "ping", "192.0.2.2", "-c", "10" });

    // Exchange raw text in both directions over one TCP connection.
    var host_output = try test_utils.TmpUartOutput.create();
    defer host_output.deinit();

    var server = try std.process.spawn(io, .{
        .argv = &.{ "python3", "-c", tcp_test_server },
        .stdin = .close,
        .stdout = .{ .file = host_output.file },
        .stderr = .inherit,
    });
    defer server.kill(io);

    try wait_for_output(&host_output, "tcp-ready");
    try input_writer.writeStreamingAll(io, "printf 'hello from guest' | socat - TCP4:192.0.2.1:12345\n");
    try wait_for_output(&host_output, "hello from guest");
    try wait_for_output(&uart_output, "hello from host");

    const term = try server.wait(io);
    try std.testing.expect(term == .exited and term.exited == 0);
}

test "Virtio net MMIO" {
    try test_virtio_net(1, false);
}

test "Virtio net PCI" {
    try test_virtio_net(1, true);
}

test "Virtio net MMIO (smp)" {
    try test_virtio_net(8, false);
}

test "Virtio net PCI (smp)" {
    try test_virtio_net(8, true);
}

test "SMP works" {
    _ = try kvm_system.get();

    const io = std.testing.io;
    const allocator = std.testing.allocator;

    try test_utils.mmap.init(allocator);
    defer test_utils.mmap.deinit() catch @panic("mmap leaked");

    const fds = try test_utils.FdLeakDetector.snapshot(io);
    defer fds.check_leak(io) catch @panic("fd leaked");

    const binary_bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "test_bins/bzImage",
        allocator,
        .unlimited,
    );
    defer allocator.free(binary_bytes);
    const initrd_bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "test_bins/initrd.img",
        allocator,
        .unlimited,
    );
    defer allocator.free(initrd_bytes);

    var uart_output = try test_utils.TmpUartOutput.create();
    defer uart_output.deinit();

    var pipe_fds: [2]posix.fd_t = undefined;
    const pipe_rc = linux.pipe2(&pipe_fds, .{ .CLOEXEC = true });
    switch (posix.errno(pipe_rc)) {
        .SUCCESS => {},
        else => |err| return posix.unexpectedErrno(err),
    }

    const uart_input: std.Io.File = .{
        .handle = pipe_fds[0],
        .flags = .{ .nonblocking = false },
    };
    defer uart_input.close(io);

    const input_writer: std.Io.File = .{
        .handle = pipe_fds[1],
        .flags = .{ .nonblocking = false },
    };
    defer input_writer.close(io);

    var vm = try Vm.new(.{
        .ram_size = 1 << 30,
        .binary = binary_bytes,
        .initramfs = initrd_bytes,
        .cmdline = "panic=default pci=off",
        .smp = 16,
    }, io, allocator);
    defer vm.deinit(allocator, io);

    try vm.attach_console(.{
        .index = 0,
        .input = uart_input,
        .output = uart_output.file,
    });

    const thread = try std.Thread.spawn(.{}, vm_run_thread, .{ vm, allocator, io });

    try login_in_initrd(&uart_output, &input_writer);

    try input_writer.writeStreamingAll(io, "cat /proc/cpuinfo | grep processor | wc -l\n");
    try wait_for_output(&uart_output, "16");

    // check that apicid is unique (i.e. cpuid fix was applied)
    try input_writer.writeStreamingAll(io, "cat /proc/cpuinfo | grep 'initial apicid' | uniq | wc -l\n");
    try wait_for_output(&uart_output, "16");

    try vm.stop();
    thread.join();
}
