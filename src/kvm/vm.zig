//! Raw KVM virtual-machine descriptor wrapper.

const c = @import("abi.zig").c;

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const Vcpu = @import("vcpu.zig").Vcpu;
const ioctl = @import("ioctl.zig").ioctl;
const cpuid = @import("cpuid.zig");

pub const GuestPhysicalAddress = u64;

pub const Vm = struct {
    fd: posix.fd_t,
    kvm_fd: posix.fd_t,
    vcpu_mmap_size: usize,

    const Self = @This();

    pub fn init(fd: posix.fd_t, kvm_fd: posix.fd_t, vcpu_mmap_size: usize) Self {
        return .{
            .fd = fd,
            .kvm_fd = kvm_fd,
            .vcpu_mmap_size = vcpu_mmap_size,
        };
    }

    pub fn set_user_memory_region(
        self: *const Self,
        guest_address: GuestPhysicalAddress,
        slot: u32,
        memory: []u8,
    ) !void {
        const region = c.kvm_userspace_memory_region{
            .flags = 0,
            .guest_phys_addr = guest_address,
            .memory_size = memory.len,
            .slot = slot,
            .userspace_addr = @intFromPtr(memory.ptr),
        };

        _ = try ioctl(self.fd, c.KVM_SET_USER_MEMORY_REGION, @intFromPtr(&region));
    }

    pub fn create_pit(self: *const Self) !void {
        const config = c.kvm_pit_config{};

        _ = try ioctl(self.fd, c.KVM_CREATE_PIT2, @intFromPtr(&config));
    }

    pub fn create_irqchip(self: *const Self) !void {
        _ = try ioctl(self.fd, c.KVM_CREATE_IRQCHIP, 0);
    }

    pub fn create_vcpu(self: *const Self, id: usize) !Vcpu {
        const fd = try ioctl(self.fd, c.KVM_CREATE_VCPU, id);
        var vcpu = try Vcpu.init(@intCast(fd), self.vcpu_mmap_size, id);
        errdefer vcpu.deinit();

        try cpuid.configure(self.kvm_fd, vcpu.fd);
        return vcpu;
    }

    pub fn deinit(self: *Self) void {
        const res = linux.close(self.fd);

        std.debug.assert(res == 0);
    }
};
