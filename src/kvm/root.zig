//! Raw wrappers around the Linux KVM API.

const c = @import("abi.zig").c;

const std = @import("std");
const posix = std.posix;
const ioctl = @import("ioctl.zig").ioctl;

pub const Vm = @import("vm.zig").Vm;
pub const Vcpu = @import("vcpu.zig").Vcpu;
pub const Segment = @import("vcpu.zig").Segment;
pub const IoResult = @import("vcpu.zig").IoResult;

const KVM_EXPECTED_API_VERSION = 12;

pub const Kvm = struct {
    fd: posix.fd_t,
    vcpu_mmap_size: usize,

    const Self = @This();

    pub fn init() !Self {
        const fd = try posix.openat(
            posix.AT.FDCWD,
            "/dev/kvm",
            .{ .ACCMODE = .RDWR, .CLOEXEC = true },
            0,
        );

        const rc = try ioctl(fd, c.KVM_GET_API_VERSION, 0);

        if (rc != KVM_EXPECTED_API_VERSION)
            return error.KvmVersionMismatch;

        const vcpu_mmap_size = try ioctl(fd, c.KVM_GET_VCPU_MMAP_SIZE, 0);
        return .{ .fd = fd, .vcpu_mmap_size = vcpu_mmap_size };
    }

    pub fn create_vm(self: *const Self) !Vm {
        const rc = try ioctl(self.fd, c.KVM_CREATE_VM, 0);

        return Vm.init(@intCast(rc), self.fd, self.vcpu_mmap_size);
    }
};
