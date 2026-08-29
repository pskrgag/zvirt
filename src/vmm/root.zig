//! Virtual-machine policy and guest setup.

const std = @import("std");
const kvm = @import("kvm");
const posix = std.posix;
const builtin = @import("builtin");
const lazy = @import("utils").Lazy.lazy;
const test_utils = @import("test_utils");
const image = @import("image/root.zig");
pub const IoResult = kvm.IoResult;

const memory = @import("memory.zig");

const arch = switch (builtin.cpu.arch) {
    .x86, .x86_64 => @import("arch/x86/root.zig"),
    else => @compileError("unsupported architecture"),
};

const MAX_VCPUS = 16;
var kvm_system = lazy(kvm.Kvm, kvm.Kvm.init);

const StopFlag = std.atomic.Value(bool);

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
    vcpus: [MAX_VCPUS]?kvm.Vcpu = .{null} ** MAX_VCPUS,
    io_bus: arch.io_bus = .{},
    mmio_bus: arch.mmio_bus = .{},
    io: std.Io,
    allocator: std.mem.Allocator,
    config: VmConfig,
    memory: memory.GuestMemory,
    stop: StopFlag = StopFlag.init(false),

    const Self = @This();

    pub fn new(config: VmConfig, io: std.Io, allocator: std.mem.Allocator) !Self {
        const system = try kvm_system.get();
        var vm = try system.create_vm();
        var mem = try memory.GuestMemory.new(allocator);

        try arch.setup_memory(&mem, &config, allocator);
        const img = try image.parse(config.binary, &mem, &config);

        for (mem.regions.items) |reg| {
            try vm.set_user_memory_region(reg.gpa, reg.slot, reg.raw);
        }

        try vm.create_irqchip();
        try arch.setup_vm(&vm);

        var self: Self = .{
            .vm = vm,
            .memory = mem,
            .io = io,
            .allocator = allocator,
            .config = config,
        };

        _ = try self.create_vcpu(img.ep, 0);
        return self;
    }

    pub fn irq_set(self: *Self, num: u32, set: bool) !void {
        try self.vm.irq_set(num, set);
    }

    pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
        for (&self.vcpus) |*vcpu| {
            if (vcpu.*) |*cpu|
                cpu.deinit();
        }

        self.vm.deinit();
        self.memory.deinit(alloc);
    }

    pub fn create_vcpu(self: *Self, ep: u64, id: usize) !*kvm.Vcpu {
        if (id >= MAX_VCPUS)
            return error.InvalidVcpuIndex;

        if (self.vcpus[id] != null)
            return error.VcpuAlreadyExists;

        self.vcpus[id] = try self.vm.create_vcpu(id);
        const vcpu = &self.vcpus[id].?;
        try arch.setup_vcpu(vcpu, ep);

        return vcpu;
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
        self.stop.store(true, .release);
        self.vcpus[0].?.immediate_exit();
    }

    pub fn run(self: *Self) !void {
        const boot_vcpu = if (self.vcpus[0]) |*vcpu|
            vcpu
        else
            return error.BootVcpuMissing;

        Self.setup_sighandler();
        var result: ?IoResult = null;

        while (!self.stop.load(.acquire)) {
            boot_vcpu.run_once(result) catch |e| {
                if (e != error.Interrupted)
                    return e;
            };

            const exit = try boot_vcpu.exit_reason();
            // std.debug.print("exit reason {any}\n", .{exit});

            switch (exit) {
                .Io => |io_req| {
                    // Detecting write to fake port, which indicates test exit
                    if (try self.io_bus.handle_io(io_req, self, self.io)) {
                        return;
                    }
                },
                .Shutdown => {
                    return;
                },
                .Halt => {
                    return;
                },
                .Mmio => |mmio| {
                    result = try self.mmio_bus.handle_mmio(mmio, self.io);
                },
                .Interrupted => {},
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

    try vm.run();

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

    try vm.run();
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

fn vm_run_thread(vm: *Vm) !void {
    try vm.run();
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

    const thread = try std.Thread.spawn(.{}, vm_run_thread, .{&vm});
    try wait_for_output(&uart_output, "login");

    // Stop the vm
    vm.ask_stop();
    _ = std.c.pthread_kill(thread.getHandle(), .USR1);
    thread.join();
}

test {
    _ = @import("image/root.zig");
}
