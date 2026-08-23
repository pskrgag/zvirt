//! Virtual-machine policy and guest setup.

const std = @import("std");
const kvm = @import("kvm");
const posix = std.posix;
const builtin = @import("builtin");
const lazy = @import("utils").Lazy.lazy;
const test_utils = @import("test_utils");

const arch = switch (builtin.cpu.arch) {
    .x86, .x86_64 => @import("arch/x86.zig"),
    else => @compileError("unsupported architecture"),
};

const MAX_VCPUS = 16;
var kvm_system = lazy(kvm.Kvm, kvm.Kvm.init);

pub const VmConfig = struct {
    // Memory size (in bytes)
    memory: usize,
};

pub const Vm = struct {
    vm: kvm.Vm,
    memory: []align(std.heap.page_size_min) u8,
    vcpus: [MAX_VCPUS]?kvm.Vcpu,
    io_bus: arch.io_bus,
    io: std.Io,
    binary: ?std.ArrayList(u8),
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn new(config: VmConfig, io: std.Io, allocator: std.mem.Allocator) !Self {
        const system = try kvm_system.get();
        const vm = try system.create_vm();
        const memory = try posix.mmap(
            null,
            config.memory,
            .{ .READ = true, .WRITE = true },
            .{ .ANONYMOUS = true, .TYPE = .PRIVATE },
            -1,
            0,
        );

        errdefer posix.munmap(memory);

        try vm.set_user_memory_region(0x1000, 0, memory);

        var self: Self = .{
            .vm = vm,
            .memory = memory,
            .vcpus = .{null} ** MAX_VCPUS,
            .io_bus = arch.io_bus{},
            .io = io,
            .binary = null,
            .allocator = allocator,
        };

        _ = try self.create_vcpu(0);
        return self;
    }

    pub fn deinit(self: *Self) void {
        if (self.binary) |*binary|
            binary.deinit(self.allocator);

        posix.munmap(self.memory);
    }

    pub fn load_binary(self: *Self, owned_binary: std.ArrayList(u8)) !void {
        var binary = owned_binary;
        errdefer binary.deinit(self.allocator);

        if (self.binary != null)
            return error.BinaryAlreadyLoaded;
        if (binary.items.len > self.memory.len)
            return error.BinaryDoesNotFitInGuestMemory;

        std.mem.copyForwards(u8, self.memory, binary.items);
        self.binary = binary;
    }

    pub fn create_vcpu(self: *Self, id: usize) !*kvm.Vcpu {
        if (id >= MAX_VCPUS)
            return error.InvalidVcpuIndex;

        if (self.vcpus[id] != null)
            return error.VcpuAlreadyExists;

        self.vcpus[id] = try self.vm.create_vcpu(id);
        const vcpu = &self.vcpus[id].?;
        try arch.setup_vcpu(vcpu);

        return vcpu;
    }

    pub fn run(self: *Self) !void {
        const boot_vcpu = if (self.vcpus[0]) |*vcpu|
            vcpu
        else
            return error.BootVcpuMissing;

        while (true) {
            try boot_vcpu.run_once();

            const exit = try boot_vcpu.exit_reason();
            // std.debug.print("exit reason {any}\n", .{exit});

            switch (exit) {
                .Io => |io_req| {
                    try self.io_bus.handle_io(io_req, self.io);
                },
                .Halt => {
                    std.debug.print("VM halts\n", .{});
                    return;
                },
            }
        }
    }
};

test "guest port write reaches COM1 UART" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var vm = try Vm.new(.{ .memory = 0x2000 }, io, allocator);
    defer vm.deinit();

    const binary_bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "test_bins/port_write.bin",
        allocator,
        .unlimited,
    );
    const binary = std.ArrayList(u8).fromOwnedSlice(binary_bytes);
    try vm.load_binary(binary);

    var uart_output = try test_utils.TmpUartOutput.create();
    defer uart_output.deinit();
    vm.io_bus.com1.file = uart_output.file;

    try vm.run();

    var captured: [16]u8 = undefined;
    try std.testing.expectEqualStrings("H", try uart_output.read(&captured));
}
