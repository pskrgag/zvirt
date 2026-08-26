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

pub const VmConfig = struct {
    // Memory size (in bytes)
    ram_size: usize,

    // Main binary
    binary: []const u8,

    // Arch config
    arch_cfg: arch.Config = .{},
};

pub const Vm = struct {
    vm: kvm.Vm,
    vcpus: [MAX_VCPUS]?kvm.Vcpu,
    io_bus: arch.io_bus,
    mmio_bus: arch.mmio_bus,
    io: std.Io,
    binary: ?std.ArrayList(u8),
    allocator: std.mem.Allocator,
    config: VmConfig,
    memory: memory.GuestMemory,

    const Self = @This();

    pub fn new(config: VmConfig, io: std.Io, allocator: std.mem.Allocator) !Self {
        const system = try kvm_system.get();
        const vm = try system.create_vm();
        var mem = try memory.GuestMemory.new(allocator);

        try arch.setup_memory(&mem, &config, allocator);
        const img = try image.parse(config.binary, &mem, &config);

        for (mem.regions.items) |reg| {
            try vm.set_user_memory_region(reg.gpa, reg.slot, reg.raw);
        }

        var self: Self = .{
            .vm = vm,
            .memory = mem,
            .vcpus = .{null} ** MAX_VCPUS,
            .io_bus = arch.io_bus{},
            .mmio_bus = arch.mmio_bus{},
            .io = io,
            .binary = null,
            .allocator = allocator,
            .config = config,
        };

        _ = try self.create_vcpu(img.ep, 0);
        return self;
    }

    pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
        if (self.binary) |*binary|
            binary.deinit(self.allocator);

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

    pub fn run(self: *Self) !void {
        const boot_vcpu = if (self.vcpus[0]) |*vcpu|
            vcpu
        else
            return error.BootVcpuMissing;

        var result: ?IoResult = null;

        while (true) {
            try boot_vcpu.run_once(result);

            const exit = try boot_vcpu.exit_reason();
            // std.debug.print("exit reason {any}\n", .{exit});

            switch (exit) {
                .Io => |io_req| {
                    result = try self.io_bus.handle_io(io_req, self.io);
                },
                .Halt => {
                    std.debug.print("VM halts\n", .{});
                    return;
                },
                .Mmio => |mmio| {
                    result = try self.mmio_bus.handle_mmio(mmio, self.io);
                },
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

    try vm.run();

    var captured: [16]u8 = undefined;
    try std.testing.expectEqualStrings("H", try uart_output.read(&captured));
}

test {
    _ = @import("image/root.zig");
}
