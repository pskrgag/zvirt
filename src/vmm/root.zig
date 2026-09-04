//! Virtual-machine policy and guest setup.

const utils = @import("utils");
const std = @import("std");
const kvm = @import("kvm");
const posix = std.posix;
const builtin = @import("builtin");
const lazy = utils.Lazy.lazy;
const test_utils = @import("test_utils");
const image = @import("image/root.zig");
const VCpu = @import("vcpu.zig").VCpu;
const Epoll = utils.Epoll.Epoll;
const EpollEvent = utils.Epoll.Event;
const linux = std.os.linux;
const EventFd = utils.EventFd.EventFd;
pub const IoResult = kvm.IoResult;

const memory = @import("memory.zig");

pub const arch = switch (builtin.cpu.arch) {
    .x86, .x86_64 => @import("arch/x86/root.zig"),
    else => @compileError("unsupported architecture"),
};

const MAX_VCPUS = 16;
var kvm_system = lazy(kvm.Kvm, kvm.Kvm.init);

const StopFlag = std.atomic.Value(bool);

const EventSource = enum(u3) {
    vcpu,
    io_bus,
};

const EventToken = packed struct(u64) {
    id: u29,
    fd: posix.fd_t,
    source: EventSource,
};

pub const VmConfig = struct {
    // Memory size (in bytes)
    ram_size: usize,

    // Main binary
    binary: []const u8,

    // Initramfs
    initramfs: ?[]const u8 = null,

    // Block device (path to the image)
    block_device: []const u8 = "",
};

pub const VmConsoleConfig = struct {
    input: ?std.Io.File = null,
    output: std.Io.File,
    configure_terminal: bool = false,
};

const VmStateKind = enum(u8) {
    Initialized,
    Running,
    Stopped,
};

const VmState = struct {
    state: std.atomic.Value(VmStateKind) = std.atomic.Value(VmStateKind).init(.Initialized),
    console_attached: bool = false,
};

pub const Vm = struct {
    vm: kvm.Vm,
    vcpus: [MAX_VCPUS]?*VCpu = .{null} ** MAX_VCPUS,
    device_bus: arch.DeviceBus,
    io: std.Io,
    config: VmConfig,
    memory: *memory.GuestMemory,
    epoll: Epoll,
    state: VmState = .{},
    old_sigaction: posix.Sigaction,

    const Self = @This();

    pub fn new(config: VmConfig, io: std.Io, allocator: std.mem.Allocator) !*Self {
        const system = try kvm_system.get();
        var self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        var vm = try system.create_vm();
        errdefer vm.deinit();

        try vm.create_irqchip();

        var mem = try memory.GuestMemory.new(allocator);
        errdefer mem.deinit(allocator);

        var device_bus = try arch.DeviceBus.new(allocator);
        errdefer device_bus.deinit(allocator, io);

        try arch.setup_vm(&vm, mem, &config, allocator);
        const img = try image.parse(config.binary, mem, &config);

        for (mem.regions.items) |reg| {
            try vm.set_user_memory_region(reg.gpa, reg.slot, reg.raw);
        }

        const old = Self.setup_sighandler();
        errdefer Self.restore_sighandler(old);

        self.* = .{
            .vm = vm,
            .memory = mem,
            .io = io,
            .config = config,
            .epoll = try Epoll.new(),
            .old_sigaction = old,
            .device_bus = device_bus,
        };
        errdefer self.epoll.deinit();

        try self.device_bus.init(&config, self, allocator, io);
        _ = try self.create_vcpu(img.ep, 0, io, allocator);

        return self;
    }

    // thread-unsafe
    pub fn attach_console(self: *Self, console: VmConsoleConfig) !void {
        if (self.state.console_attached)
            return error.ConsoleAlreadyAttached;

        if (self.state.state.load(.monotonic) != .Initialized)
            return error.InvalidState;

        try self.device_bus.attach_console(&console, self);
        self.state.console_attached = true;
    }

    pub fn irq_set(self: *Self, num: u32, set: bool) !void {
        try self.vm.irq_set(num, set);
    }

    pub fn deinit(self: *Self, alloc: std.mem.Allocator, io: std.Io) void {
        for (self.vcpus) |vcpu| {
            if (vcpu) |cpu|
                cpu.deinit(alloc, io);
        }

        try arch.deinit_vm(self.memory, &self.config);
        self.epoll.deinit();
        self.device_bus.deinit(alloc, io);
        self.vm.deinit();
        self.memory.deinit(alloc);
        Self.restore_sighandler(self.old_sigaction);
        alloc.destroy(self);
    }

    pub fn create_vcpu(
        self: *Self,
        ep: u64,
        id: usize,
        io: std.Io,
        alloc: std.mem.Allocator,
    ) !*VCpu {
        if (id >= MAX_VCPUS)
            return error.InvalidVcpuIndex;

        if (self.vcpus[id] != null)
            return error.VcpuAlreadyExists;

        self.vcpus[id] = try VCpu.new(self, id, ep, io, alloc);
        return self.vcpus[id].?;
    }

    fn wake_handler(_: std.posix.SIG) callconv(.c) void {}

    fn restore_sighandler(sa: std.posix.Sigaction) void {
        std.posix.sigaction(.USR1, &sa, null);
    }

    fn setup_sighandler() std.posix.Sigaction {
        var old: std.posix.Sigaction = undefined;
        const action = std.posix.Sigaction{
            .handler = .{ .handler = @alignCast(&wake_handler) },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };

        std.posix.sigaction(.USR1, &action, &old);
        return old;
    }

    pub fn stop(self: *Vm) !void {
        if (self.state.state.cmpxchgStrong(
            .Running,
            .Stopped,
            .monotonic,
            .monotonic,
        ) != null) {
            return error.InvalidState;
        }

        for (self.vcpus) |vcpu| {
            if (vcpu) |cpu|
                cpu.stop();
        }
    }

    pub fn register_fd(self: *Self, fd: posix.fd_t, id: u29, source: EventSource) !void {
        const token = EventToken{
            .id = id,
            .fd = fd,
            .source = source,
        };

        try self.epoll.add(fd, @bitCast(token));
    }

    pub fn run(self: *Self, alloc: std.mem.Allocator, io: std.Io) !void {
        if (self.state.state.cmpxchgStrong(
            .Initialized,
            .Running,
            .monotonic,
            .monotonic,
        ) != null) {
            return error.AlreadyStarted;
        }

        try arch.vm_prerun(self.memory, &self.device_bus, alloc);

        for (self.vcpus, 0..) |vcpu, idx| {
            if (vcpu) |cpu| {
                try self.register_fd(cpu.eventfd.fd, @truncate(idx), .vcpu);
                cpu.start(io);
            }
        }

        var panic_cpu: ?u64 = null;

        while (true) {
            var event_buffer: [1]EpollEvent = undefined;

            const events = try self.epoll.pwait(&event_buffer, -1, linux.sigfillset());
            for (events) |event| {
                const token: EventToken = @bitCast(event.data);

                switch (token.source) {
                    .vcpu => {
                        const eventfd = EventFd{ .fd = @intCast(token.fd) };

                        // Read anyway to avoid hitting the same event.
                        _ = try eventfd.read();

                        // Only abort when vCPU panicked
                        if (self.vcpus[token.id].?.get_exit_reason() != .None) {
                            panic_cpu = token.id;
                            break;
                        }
                    },
                    .io_bus => {
                        try self.device_bus.handle_event(token.id, self, io);
                    },
                }
            }

            if (panic_cpu) |pcpu| {
                for (self.vcpus, 0..) |vcpu, idx| {
                    if (vcpu) |cpu| {
                        if (idx != pcpu) {
                            cpu.stop();
                        }
                    }
                }

                break;
            }
        }

        self.state.state.store(.Stopped, .monotonic);
    }
};

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
    try vm.run(allocator, io);
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
            .output = std.Io.File.stdout(),
        });

        try std.testing.expectError(error.ConsoleAlreadyAttached, vm.attach_console(.{
            .output = std.Io.File.stdout(),
        }));
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

        const thread = try std.Thread.spawn(.{}, vm_run_thread, .{ vm, io });

        // Busy loop until vm starts...
        while (vm.state.state.load(.monotonic) != .Running) {}

        try std.testing.expectError(error.InvalidState, vm.attach_console(.{
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

    try vm.run(allocator, io);
    try std.testing.expectError(error.AlreadyStarted, vm.run(allocator, io));
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
        try vm.run(allocator, io);
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

        const thread = try std.Thread.spawn(.{}, vm_run_thread, .{ vm, io });

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
    var vm = try Vm.new(.{
        .ram_size = 0x20000,
        .binary = binary_bytes,
    }, io, allocator);
    defer vm.deinit(allocator, io);

    var uart_output = try test_utils.TmpUartOutput.create();
    defer uart_output.deinit();
    try vm.attach_console(.{
        .output = uart_output.file,
    });

    try vm.run(allocator, io);

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

    var vm = try Vm.new(.{
        .ram_size = 1 << 30,
        .binary = binary_bytes,
    }, io, allocator);
    defer vm.deinit(allocator, io);

    var uart_output = try test_utils.TmpUartOutput.create();
    defer uart_output.deinit();
    try vm.attach_console(.{
        .output = uart_output.file,
    });

    try vm.run(allocator, io);
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

    var vm = try Vm.new(.{
        .ram_size = 1 << 30,
        .binary = binary_bytes,
        .initramfs = initrd_bytes,
    }, io, allocator);
    defer vm.deinit(allocator, io);

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

    try vm.attach_console(.{
        .input = uart_input,
        .output = uart_output.file,
    });

    const thread = try std.Thread.spawn(.{}, vm_run_thread, .{ vm, io });

    // Login discards all input data after <enter>. So we need to push data lock-step.
    try wait_for_output(&uart_output, "login");
    try input_writer.writeStreamingAll(io, "root\n");

    try wait_for_output(&uart_output, "Password:");
    try input_writer.writeStreamingAll(io, "root\n");

    try wait_for_output(&uart_output, "# ");
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

    var vm = try Vm.new(.{
        .ram_size = 1 << 30,
        .binary = binary_bytes,
        .initramfs = initrd_bytes,
    }, io, allocator);
    defer vm.deinit(allocator, io);

    var uart_output = try test_utils.TmpUartOutput.create();
    defer uart_output.deinit();
    try vm.attach_console(.{
        .output = uart_output.file,
    });

    const thread = try std.Thread.spawn(.{}, vm_run_thread, .{ vm, io });
    try wait_for_output(&uart_output, "login");

    // Stop the vm
    try vm.stop();
    thread.join();
}

test {
    _ = @import("image/root.zig");
}
