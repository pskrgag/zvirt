//! Raw KVM virtual-machine descriptor wrapper.

const c = @import("abi.zig").c;

const utils = @import("utils");
const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const Vcpu = @import("vcpu.zig").Vcpu;
const ioctl = @import("ioctl.zig").ioctl;
const cpuid = @import("cpuid.zig");
const EventFd = utils.EventFd.EventFd;

pub const GuestPhysicalAddress = u64;

pub const Vm = struct {
    fd: posix.fd_t,
    kvm_fd: posix.fd_t,
    vcpu_mmap_size: usize,

    const Self = @This();
    pub const PitState = c.kvm_pit_state2;

    // Keep the union payload opaque: translate-c cannot represent its IOAPIC bitfields.
    const ChipState = extern struct {
        chip_id: u32,
        pad: u32,
        chip: [512]u8 align(8),
    };

    pub const IrqState = [3]ChipState;

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

    pub fn snapshot_pit(self: *const Self) !PitState {
        var state: PitState = undefined;

        _ = try ioctl(self.fd, c.KVM_GET_PIT2, @intFromPtr(&state));
        return state;
    }

    pub fn restore_pit(self: *Self, pit: PitState) !void {
        try self.create_pit();
        _ = try ioctl(self.fd, c.KVM_SET_PIT2, @intFromPtr(&pit));
    }

    pub fn register_irq(self: *const Self, eventfd: *const EventFd, num: u32) !void {
        const arg = c.kvm_irqfd{
            .fd = @intCast(eventfd.as_fd()),
            .gsi = num,
        };

        _ = try ioctl(self.fd, c.KVM_IRQFD, @intFromPtr(&arg));
    }

    pub fn register_ioevent(
        self: *const Self,
        eventfd: *const EventFd,
        address: u64,
        len: u32,
        datamatch: u64,
    ) !void {
        const arg = c.kvm_ioeventfd{
            .datamatch = datamatch,
            .addr = address,
            .len = len,
            .fd = @intCast(eventfd.as_fd()),
            .flags = c.KVM_IOEVENTFD_FLAG_DATAMATCH,
        };

        _ = try ioctl(self.fd, c.KVM_IOEVENTFD, @intFromPtr(&arg));
    }

    pub fn msi_signal(self: *const Self, address_lo: u32, address_hi: u32, data: u32) !void {
        var irq = c.kvm_msi{
            .address_hi = address_hi,
            .address_lo = address_lo,
            .data = data,
            .flags = 0,
            .devid = 0,
            .pad = @splat(0),
        };

        _ = try ioctl(self.fd, c.KVM_SIGNAL_MSI, @intFromPtr(&irq));
    }

    pub fn snapshot_irqchip(self: *const Self) !IrqState {
        var state: [3]ChipState = @splat(std.mem.zeroes(ChipState));

        state[0].chip_id = 0;
        state[1].chip_id = 1;
        state[2].chip_id = 2;

        for (0..3) |i| {
            _ = try ioctl(self.fd, linux.IOCTL.IOWR(c.KVMIO, 0x62, ChipState), @intFromPtr(&state[i]));
        }

        return state;
    }

    pub fn restore_irqchip(self: *Self, irq: IrqState) !void {
        try self.create_irqchip();

        for (0..3) |i| {
            _ = try ioctl(self.fd, linux.IOCTL.IOR(c.KVMIO, 0x63, ChipState), @intFromPtr(&irq[i]));
        }
    }

    pub fn create_irqchip(self: *const Self) !void {
        _ = try ioctl(self.fd, c.KVM_CREATE_IRQCHIP, 0);
    }

    pub fn create_vcpu(self: *const Self, id: u32, num_cpus: u32) !Vcpu {
        const fd = try ioctl(self.fd, c.KVM_CREATE_VCPU, id);
        var vcpu = try Vcpu.init(@intCast(fd), self.fd, self.kvm_fd, self.vcpu_mmap_size, id);
        errdefer vcpu.deinit();

        try cpuid.configure(self.kvm_fd, id, num_cpus, vcpu.fd);
        return vcpu;
    }

    pub fn deinit(self: *Self) void {
        const res = linux.close(self.fd);

        std.debug.assert(res == 0);
    }
};
