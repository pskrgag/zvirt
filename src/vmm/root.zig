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

    // Arch config
    arch_cfg: arch.Config = .{},
};

pub const Vm = struct {
    vm: kvm.Vm,
    vcpus: [MAX_VCPUS]?*VCpu = .{null} ** MAX_VCPUS,
    io_bus: arch.io_bus = .{},
    mmio_bus: arch.mmio_bus = .{},
    io: std.Io,
    allocator: std.mem.Allocator,
    config: VmConfig,
    memory: memory.GuestMemory,
    stop: StopFlag = StopFlag.init(false),
    epoll: Epoll,

    const Self = @This();

    pub fn new(config: VmConfig, io: std.Io, allocator: std.mem.Allocator) !*Self {
        const system = try kvm_system.get();
        var self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        var vm = try system.create_vm();
        errdefer vm.deinit();

        var mem = try memory.GuestMemory.new(allocator);
        errdefer mem.deinit(allocator);

        try arch.setup_memory(&mem, &config, allocator);
        const img = try image.parse(config.binary, &mem, &config);

        for (mem.regions.items) |reg| {
            try vm.set_user_memory_region(reg.gpa, reg.slot, reg.raw);
        }

        try vm.create_irqchip();
        try arch.setup_vm(&vm);

        self.* = .{
            .vm = vm,
            .memory = mem,
            .io = io,
            .allocator = allocator,
            .config = config,
            .epoll = try Epoll.new(),
        };

        _ = try self.create_vcpu(img.ep, 0, io, allocator);
        return self;
    }

    pub fn irq_set(self: *Self, num: u32, set: bool) !void {
        try self.vm.irq_set(num, set);
    }

    pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
        for (self.vcpus) |vcpu| {
            if (vcpu) |cpu|
                cpu.deinit(alloc);
        }

        self.vm.deinit();
        self.memory.deinit(alloc);
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

    fn setup_sighandler() void {
        const action = std.posix.Sigaction{
            .handler = .{ .handler = @alignCast(&wake_handler) },
            .mask = std.posix.sigemptyset(),
            .flags = 0, // no SA_RESTART
        };

        std.posix.sigaction(.USR1, &action, null);
    }

    pub fn ask_stop(self: *Vm) void {
        for (self.vcpus) |vcpu| {
            if (vcpu) |cpu|
                cpu.stop();
        }
    }

    fn register_fd(self: *Self, fd: posix.fd_t, id: u29, source: EventSource) !void {
        const token = EventToken{
            .id = id,
            .fd = fd,
            .source = source,
        };

        try self.epoll.add(fd, @bitCast(token));
    }

    pub fn run(self: *Self, io: std.Io) !void {
        Self.setup_sighandler();

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
    }
};

test "guest port write reaches COM1 UART" {
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
    defer vm.deinit(allocator);

    var uart_output = try test_utils.TmpUartOutput.create();
    defer uart_output.deinit();
    vm.io_bus.com1.file = uart_output.file;
    defer vm.io_bus.com1.file = std.Io.File.stdout();

    try vm.run(io);

    var captured: [16]u8 = undefined;
    try std.testing.expectEqualStrings("H", try uart_output.read(&captured));
}

test "linux reaches shutdown" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
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
    defer vm.deinit(allocator);

    var uart_output = try test_utils.TmpUartOutput.create();
    defer uart_output.deinit();
    vm.io_bus.com1.file = uart_output.file;
    defer vm.io_bus.com1.file = std.Io.File.stdout();

    try vm.run(io);
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

fn vm_run_thread(vm: *Vm, io: std.Io) !void {
    try vm.run(io);
}

test "linux reaches console" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
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
    defer vm.deinit(allocator);

    var uart_output = try test_utils.TmpUartOutput.create();
    defer uart_output.deinit();
    vm.io_bus.com1.file = uart_output.file;
    defer vm.io_bus.com1.file = std.Io.File.stdout();

    const thread = try std.Thread.spawn(.{}, vm_run_thread, .{ vm, io });
    try wait_for_output(&uart_output, "login");

    // Stop the vm
    vm.ask_stop();
    thread.join();
}

test {
    _ = @import("image/root.zig");
}
