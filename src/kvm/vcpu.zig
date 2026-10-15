//! Raw KVM vCPU descriptor wrapper.

const c = @import("abi.zig").c;

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const ioctl = @import("ioctl.zig").ioctl;
const mmap = @import("test_utils").mmap;

pub const Regs = c.kvm_regs;
pub const Sregs = c.kvm_sregs;
pub const Sregs2 = c.kvm_sregs2;

pub const Segment = c.kvm_segment;
pub const LapicState = c.kvm_lapic_state;
pub const VCpuEvents = c.kvm_vcpu_events;
pub const MpState = c.kvm_mp_state;
pub const Xcrs = c.kvm_xcrs;
pub const MsrEntry = c.kvm_msr_entry;

const MAX_MSRS = 1024;
const MAX_XSAVE_BYTES = 64 * 1024;
const log = std.log.scoped(.kvm_vcpu);

pub const MsrState = extern struct {
    nmsrs: u32 = 0,
    pad: u32 = 0,
    entries: [MAX_MSRS]MsrEntry = @splat(.{}),
};

pub const XsaveState = extern struct {
    len: u32,
    bytes: [MAX_XSAVE_BYTES]u8 align(64),
};

pub const ExitReasonRaw = enum(usize) {
    Halt = c.KVM_EXIT_HLT,
    Io = c.KVM_EXIT_IO,
    Mmio = c.KVM_EXIT_MMIO,
    Shutdown = c.KVM_EXIT_SHUTDOWN,
    Interrupted = c.KVM_EXIT_INTR,
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
        len: usize,
    },
    Shutdown: void,
    Interrupted: void,
};

pub const IoResult = union(enum) {
    Mmio: struct {
        data: u64,
    },
};

pub const Vcpu = struct {
    fd: posix.fd_t,
    // Borrowed descriptors; the VM and KVM system must outlive the vCPU.
    vm_fd: posix.fd_t,
    kvm_fd: posix.fd_t,
    run: *c.kvm_run,
    run_mapping: []align(std.heap.page_size_min) u8,
    id: usize,

    const Self = @This();

    pub fn init(
        fd: posix.fd_t,
        vm_fd: posix.fd_t,
        kvm_fd: posix.fd_t,
        mmap_size: usize,
        id: usize,
    ) !Self {
        const run_mapping = try mmap.mmap(
            null,
            mmap_size,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            fd,
            0,
        );

        return .{
            .fd = fd,
            .vm_fd = vm_fd,
            .kvm_fd = kvm_fd,
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

    pub fn get_msrs(self: *const Self) !MsrState {
        const MsrList = extern struct {
            nmsrs: u32 = MAX_MSRS,
            indices: [MAX_MSRS]u32 = @splat(0),
        };
        var indices = MsrList{};

        const rc = linux.ioctl(self.kvm_fd, c.KVM_GET_MSR_INDEX_LIST, @intFromPtr(&indices));

        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .@"2BIG" => return error.MsrCapacityExceeded,
            else => return error.IoctlFailed,
        }

        if (indices.nmsrs > MAX_MSRS) {
            return error.MsrListTooBig;
        }

        var state = MsrState{ .nmsrs = indices.nmsrs };

        for (state.entries[0..state.nmsrs], indices.indices[0..state.nmsrs]) |*entry, index| {
            entry.index = index;
        }

        const read = try ioctl(self.fd, c.KVM_GET_MSRS, @intFromPtr(&state));
        if (read != state.nmsrs) {
            if (read < state.nmsrs) {
                log.err("failed to read MSR 0x{x}", .{state.entries[read].index});
            }

            return error.IncompleteMsrRead;
        }

        return state;
    }

    pub fn set_msrs(self: *const Self, entries: []const MsrEntry) !void {
        if (entries.len == 0) {
            return;
        }

        if (entries.len > MAX_MSRS) {
            return error.MsrCapacityExceeded;
        }

        var state = MsrState{ .nmsrs = @intCast(entries.len) };
        @memcpy(state.entries[0..entries.len], entries);

        const written = try ioctl(self.fd, c.KVM_SET_MSRS, @intFromPtr(&state));
        if (written != entries.len) {
            if (written < entries.len) {
                log.err("failed to restore MSR 0x{x}", .{entries[written].index});
            }
            return error.IncompleteMsrWrite;
        }
    }

    fn xsave_size(self: *const Self) !usize {
        const size = try ioctl(self.vm_fd, c.KVM_CHECK_EXTENSION, c.KVM_CAP_XSAVE2);

        if (size != 0) {
            if (size < 4096 or size > MAX_XSAVE_BYTES) {
                return error.UnsupportedXsaveSize;
            }

            return size;
        }

        return 4096;
    }

    pub fn get_xsave(self: *const Self) !XsaveState {
        var state = XsaveState{
            .len = @intCast(try self.xsave_size()),
            .bytes = @splat(0),
        };

        _ = try ioctl(self.fd, c.KVM_GET_XSAVE2, @intFromPtr(&state.bytes));
        return state;
    }

    pub fn set_xsave(self: *const Self, state: *const XsaveState) !void {
        if (state.len != try self.xsave_size()) {
            return error.XsaveSizeMismatch;
        }

        _ = try ioctl(self.fd, c.KVM_SET_XSAVE, @intFromPtr(&state.bytes));
    }

    pub fn get_xcrs(self: *const Self) !Xcrs {
        var state = std.mem.zeroes(Xcrs);

        _ = try ioctl(self.fd, c.KVM_GET_XCRS, @intFromPtr(&state));
        return state;
    }

    pub fn set_xcrs(self: *const Self, state: *const Xcrs) !void {
        _ = try ioctl(self.fd, c.KVM_SET_XCRS, @intFromPtr(state));
    }

    pub fn get_tsc_khz(self: *const Self) !u32 {
        return @intCast(try ioctl(self.fd, c.KVM_GET_TSC_KHZ, 0));
    }

    pub fn set_tsc_khz(self: *const Self, khz: u32) !void {
        if (try ioctl(self.vm_fd, c.KVM_CHECK_EXTENSION, c.KVM_CAP_TSC_CONTROL) != 0) {
            _ = try ioctl(self.fd, c.KVM_SET_TSC_KHZ, khz);
        } else if (khz != try self.get_tsc_khz()) {
            return error.TscFrequencyMismatch;
        }
    }

    pub fn get_mp_state(self: *const Self) !MpState {
        var state: MpState = undefined;

        _ = try ioctl(self.fd, c.KVM_GET_MP_STATE, @intFromPtr(&state));
        return state;
    }

    pub fn set_mp_state(self: *const Self, state: *const MpState) !void {
        _ = try ioctl(self.fd, c.KVM_SET_MP_STATE, @intFromPtr(state));
    }

    pub fn get_lapic(self: *const Self) !LapicState {
        var state: LapicState = undefined;

        _ = try ioctl(self.fd, c.KVM_GET_LAPIC, @intFromPtr(&state));
        return state;
    }

    pub fn set_lapic(self: *const Self, lapic: *const LapicState) !void {
        _ = try ioctl(self.fd, c.KVM_SET_LAPIC, @intFromPtr(lapic));
    }

    pub fn get_vcpu_events(self: *const Self) !VCpuEvents {
        var state: VCpuEvents = undefined;

        _ = try ioctl(self.fd, c.KVM_GET_VCPU_EVENTS, @intFromPtr(&state));
        return state;
    }

    pub fn set_vcpu_events(self: *Self, state: *const VCpuEvents) !void {
        _ = try ioctl(self.fd, c.KVM_SET_VCPU_EVENTS, @intFromPtr(state));
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
        const raw = try (std.enums.fromInt(
            ExitReasonRaw,
            self.run.exit_reason,
        ) orelse error.UnknownExitReason);

        return switch (raw) {
            .Halt => .Halt,
            .Shutdown => .Shutdown,
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
                .len = self.run.unnamed_0.mmio.len,
            } },
            .Interrupted => .Interrupted,
        };
    }

    pub fn deinit(self: *Self) void {
        mmap.munmap(self.run_mapping);

        const res = linux.close(@intCast(self.fd));
        std.debug.assert(res == 0);
    }

    pub fn immediate_exit(self: *Self) void {
        @atomicStore(u8, &self.run.immediate_exit, 1, .monotonic);
    }

    pub fn run_once(self: *const Self, result: ?IoResult) !void {
        if (result) |res| {
            switch (res) {
                .Mmio => |mmio| {
                    self.run.unnamed_0.mmio.data = @bitCast(mmio.data);
                },
            }
        }

        _ = try ioctl(self.fd, c.KVM_RUN, 0);
    }
};
