//! x86 machine setup policy.

const std = @import("std");
const kvm = @import("kvm");
const GuestMemory = @import("../memory.zig").GuestMemory;
const VmConfig = @import("../root.zig").VmConfig;
const posix = std.posix;
const Allocator = std.mem.Allocator;

const DEFAULT_LOAD_ADDRESS_REAL = 0x1000;

pub const io_bus = @import("io_bus.zig");

pub const Mode = enum(u8) {
    Real,
    Long,
};

pub const Config = struct {
    mode: Mode = .Long,
};

pub fn setup_vcpu(vcpu: *kvm.Vcpu, config: *const Config) !void {
    if (config.mode == .Real) {
        var sregs = try vcpu.get_sregs();
        sregs.cs.base = 0;
        sregs.cs.selector = 0;
        try vcpu.set_sregs(&sregs);

        var regs = try vcpu.get_regs();
        regs.rip = DEFAULT_LOAD_ADDRESS_REAL;
        try vcpu.set_regs(&regs);
    }
}

pub fn setup_memory(memory: *GuestMemory, config: VmConfig, alloc: Allocator) !void {
    const ram = try posix.mmap(
        null,
        config.ram_size,
        .{ .READ = true, .WRITE = true },
        .{ .ANONYMOUS = true, .TYPE = .PRIVATE },
        -1,
        0,
    );

    try memory.allocate(0x0, ram, alloc);

    if (config.arch_cfg.mode == .Real)
        try memory.write(DEFAULT_LOAD_ADDRESS_REAL, config.binary);
}
