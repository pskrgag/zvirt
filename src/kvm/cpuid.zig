//! Raw wrappers for configuring a KVM vCPU's CPUID table.

const c = @import("abi.zig").c;
const std = @import("std");
const posix = std.posix;
const ioctl = @import("ioctl.zig").ioctl;

const MAX_ENTRIES = 256;

const Cpuid = extern struct {
    nent: u32,
    padding: u32,
    entries: [MAX_ENTRIES]c.kvm_cpuid_entry2,
};

pub fn configure(kvm_fd: posix.fd_t, vcpu_fd: posix.fd_t) !void {
    var cpuid: Cpuid = .{
        .nent = MAX_ENTRIES,
        .padding = 0,
        .entries = undefined,
    };

    _ = try ioctl(
        kvm_fd,
        c.KVM_GET_SUPPORTED_CPUID,
        @intFromPtr(&cpuid),
    );

    _ = try ioctl(
        vcpu_fd,
        c.KVM_SET_CPUID2,
        @intFromPtr(&cpuid),
    );
}
