//! Raw KVM vCPU descriptor wrapper.

const c = @cImport({
    @cInclude("linux/kvm.h");
});

const std = @import("std");
const posix = std.posix;
const ioctl = @import("ioctl.zig").ioctl;

pub const Regs = c.kvm_regs;
pub const Sregs = c.kvm_sregs;

pub const ExitReasonRaw = enum(usize) {
    Halt = c.KVM_EXIT_HLT,
    Io = c.KVM_EXIT_IO,
};

pub const IoDirection = enum(u8) {
    Out = c.KVM_EXIT_IO_OUT,
    In = c.KVM_EXIT_IO_IN,
};

pub const ExitReason = union(ExitReasonRaw) {
    Halt: void,
    Io: struct {
        dir: IoDirection,
        size: u8,
        port: u16,
        count: u32,
        data: *u8,
    },
};

pub const Vcpu = struct {
    fd: posix.fd_t,
    run: *c.kvm_run,
    run_mapping: []align(std.heap.page_size_min) u8,
    id: usize,

    const Self = @This();

    pub fn init(fd: posix.fd_t, mmap_size: usize, id: usize) !Self {
        const run_mapping = try posix.mmap(
            null,
            mmap_size,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            fd,
            0,
        );

        return .{
            .fd = fd,
            .run = @ptrCast(run_mapping.ptr),
            .run_mapping = run_mapping,
            .id = id,
        };
    }

    pub fn get_regs(self: *const Self) !Regs {
        var regs: Regs = undefined;

        _ = try ioctl(self.fd, c.KVM_GET_REGS, @intFromPtr(&regs));
        return regs;
    }

    pub fn set_regs(self: *const Self, regs: *const Regs) !void {
        _ = try ioctl(self.fd, c.KVM_SET_REGS, @intFromPtr(regs));
    }

    pub fn get_sregs(self: *const Self) !Sregs {
        var sregs: Sregs = undefined;

        _ = try ioctl(self.fd, c.KVM_GET_SREGS, @intFromPtr(&sregs));
        return sregs;
    }

    pub fn set_sregs(self: *const Self, sregs: *const Sregs) !void {
        _ = try ioctl(self.fd, c.KVM_SET_SREGS, @intFromPtr(sregs));
    }

    pub fn exit_reason(self: *const Self) !ExitReason {
        const raw = try (std.enums.fromInt(
            ExitReasonRaw,
            self.run.exit_reason,
        ) orelse error.UnknownExitReason);

        return switch (raw) {
            .Halt => .Halt,
            .Io => blk: {
                const dir = try (std.enums.fromInt(
                    IoDirection,
                    self.run.unnamed_0.io.direction,
                ) orelse error.UnknownIoDirection);

                break :blk .{ .Io = .{
                    .dir = dir,
                    .size = self.run.unnamed_0.io.size,
                    .port = self.run.unnamed_0.io.port,
                    .data = @ptrFromInt(@intFromPtr(self.run) + self.run.unnamed_0.io.data_offset),
                    .count = self.run.unnamed_0.io.count,
                } };
            },
        };
    }

    pub fn deinit(self: *Self) void {
        posix.munmap(self.run_mapping);
    }

    pub fn run_once(self: *const Self) !void {
        _ = try ioctl(self.fd, c.KVM_RUN, 0);
    }
};
