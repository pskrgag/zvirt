//! Raw KVM vCPU descriptor wrapper.

const c = @import("abi.zig").c;

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const ioctl = @import("ioctl.zig").ioctl;

pub const Regs = c.kvm_regs;
pub const Sregs = c.kvm_sregs;
pub const Sregs2 = c.kvm_sregs2;
pub const Segment = c.kvm_segment;

pub const ExitReasonRaw = enum(usize) {
    Halt = c.KVM_EXIT_HLT,
    Io = c.KVM_EXIT_IO,
    Mmio = c.KVM_EXIT_MMIO,
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
    Mmio: struct {
        pa: u64,
        data: u64,
        write: bool,
    },
};

pub const IoResult = union(enum) {
    Io: void,
    Mmio: struct {
        data: u64,
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

    pub fn get_sregs2(self: *const Self) !Sregs2 {
        var sregs: Sregs2 = undefined;

        _ = try ioctl(self.fd, c.KVM_GET_SREGS2, @intFromPtr(&sregs));
        return sregs;
    }

    pub fn set_sregs2(self: *const Self, sregs: *const Sregs2) !void {
        _ = try ioctl(self.fd, c.KVM_SET_SREGS2, @intFromPtr(sregs));
    }

    pub fn set_sregs(self: *const Self, sregs: *const Sregs) !void {
        _ = try ioctl(self.fd, c.KVM_SET_SREGS, @intFromPtr(sregs));
    }

    pub fn exit_reason(self: *const Self) !ExitReason {
        // std.debug.print("exit reason {}\n", .{self.run.exit_reason});
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
            .Mmio => .{ .Mmio = .{
                .data = @bitCast(self.run.unnamed_0.mmio.data),
                .write = self.run.unnamed_0.mmio.is_write == 1,
                .pa = self.run.unnamed_0.mmio.phys_addr,
            } },
        };
    }

    pub fn deinit(self: *Self) void {
        posix.munmap(self.run_mapping);

        const res = linux.close(@intCast(self.fd));
        std.debug.assert(res == 0);
    }

    pub fn run_once(self: *const Self, result: ?IoResult) !void {
        if (result) |res| {
            switch (res) {
                .Io => |io| {
                    _ = io;
                },
                .Mmio => |mmio| {
                    self.run.unnamed_0.mmio.data = @bitCast(mmio.data);
                },
            }
        }

        _ = try ioctl(self.fd, c.KVM_RUN, 0);
    }
};
