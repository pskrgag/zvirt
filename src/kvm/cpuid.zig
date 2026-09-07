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

pub fn configure(kvm_fd: posix.fd_t, id: u32, num_cpus: u32, vcpu_fd: posix.fd_t) !void {
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

    for (0..cpuid.nent) |i| {
        if (cpuid.entries[i].function == 0xB) {
            cpuid.entries[i].edx = id;
        } else if (cpuid.entries[i].function == 0x1) {
            cpuid.entries[i].ebx =
                (cpuid.entries[i].ebx & 0x0000_ffff) |
                (@as(u32, num_cpus) << 16) |
                (@as(u32, id & 0xff) << 24);
        }
    }

    _ = try ioctl(
        vcpu_fd,
        c.KVM_SET_CPUID2,
        @intFromPtr(&cpuid),
    );
}
