//! Virtual CPU

const utils = @import("utils");
const std = @import("std");
const kvm = @import("kvm");
const Vm = @import("root.zig").Vm;
const arch = @import("root.zig").arch;
const Event = std.Io.Event;
const StopFlag = std.atomic.Value(bool);
const IoResult = kvm.IoResult;
const EventFd = utils.EventFd.EventFd;
const log = std.log.scoped(.vcpu);

pub const VCpuExitReason = enum(u8) {
    Shutdown,
    UnhandledException,
    TestExit,
    Aborted,
    InternalError,
    None,
};

const ExitReason = std.atomic.Value(VCpuExitReason);

pub const VCpuState = struct {
    regs: kvm.vcpu.Regs,
    sregs: kvm.vcpu.Sregs,
    sregs2: kvm.vcpu.Sregs2,
};

pub const VCpu = struct {
    cpu: kvm.vcpu.Vcpu,
    num: usize,
    vm: *Vm,
    thread: std.Thread = undefined,
    start_event: Event = .unset,
    stop_flag: StopFlag = StopFlag.init(false),
    eventfd: EventFd,
    exit_reason: ExitReason = ExitReason.init(.None),
    exit_event: std.Io.Event = .unset,

    const Self = @This();

    pub fn new(vm: *Vm, num: u32, ep: u64, io: std.Io, alloc: std.mem.Allocator) !*Self {
        var c = try vm.vm.create_vcpu(num, 16);
        errdefer c.deinit();

        const self = try alloc.create(Self);
        errdefer alloc.destroy(self);

        var eventfd = try EventFd.new(0);
        errdefer eventfd.deinit();

        self.* = .{
            .cpu = c,
            .num = num,
            .vm = vm,
            .eventfd = eventfd,
        };

        // NOTE: it makes sense to only initialize BS cpu, since kernel will anyway set the context
        // on cpu wakeup
        if (num == 0)
            try arch.setup_bs_vcpu(&c, ep);

        self.thread = try std.Thread.spawn(.{}, Self.run_loop, .{ self, io });
        return self;
    }

    pub fn start(self: *Self, io: std.Io) void {
        self.start_event.set(io);
    }

    pub fn get_exit_reason(self: *const Self) VCpuExitReason {
        return self.exit_reason.load(.monotonic);
    }

    pub fn stop(self: *Self) void {
        self.cpu.immediate_exit();
        self.stop_flag.store(true, .monotonic);

        _ = self.exit_reason.cmpxchgStrong(.None, .Aborted, .release, .monotonic);
        _ = std.c.pthread_kill(self.thread.getHandle(), .USR1);
    }

    pub fn deinit(self: *Self, alloc: std.mem.Allocator, io: std.Io) void {
        self.start_event.set(io);
        self.stop();
        self.thread.join();
        self.eventfd.deinit();

        self.cpu.deinit();
        alloc.destroy(self);
    }

    pub fn ack_event(self: *Self) !?VCpuExitReason {
        // Read anyway to avoid hitting the same event.
        _ = try self.eventfd.read();

        return self.get_exit_reason();
    }

    pub fn snapshot(self: *const Self) !VCpuState {
        // TODO: check that CPU is not running
        const regs = try self.cpu.get_regs();
        const sregs = try self.cpu.get_sregs();
        const sregs2 = try self.cpu.get_sregs2();

        return .{ .regs = regs, .sregs = sregs, .sregs2 = sregs2 };
    }

    pub fn wait_exit(self: *Self, io: std.Io) !void {
        try self.exit_event.wait(io);
    }

    fn run_loop(self: *Self, io: std.Io) !void {
        try self.start_event.wait(io);
        var result: ?IoResult = null;

        // May happen if smth went wrong on syscall level.
        errdefer {
            self.exit_reason.store(.InternalError, .monotonic);
        }

        // Once thread reaches the end of the function, vCPU is dead. Signal it to the main thread.
        defer {
            self.exit_event.set(io);
            self.eventfd.notify() catch @panic("no idea how to handle it");
        }

        while (!self.stop_flag.load(.monotonic)) {
            self.cpu.run_once(result) catch |e| {
                if (e == error.Retry)
                    continue;

                if (e != error.Interrupted)
                    return e;

                // Continue the loop. If it was stop signal, stop_flag would be set.
                continue;
            };

            const reason = self.cpu.exit_reason() catch {
                log.warn("unknown exit reason", .{});
                self.exit_reason.store(.InternalError, .monotonic);
                break;
            };

            switch (reason) {
                .Io => |io_req| {
                    self.vm.stats().inc(.vmexit_io);

                    try self.vm.archvm.device_bus.handle_io(io_req, io);
                },
                .Shutdown => {
                    self.exit_reason.store(.Shutdown, .monotonic);
                    break;
                },
                .Mmio => |mmio| {
                    self.vm.stats().inc(.vmexit_mmio);
                    result = try self.vm.archvm.device_bus.handle_mmio(mmio, io);
                },
                .Interrupted => {},
                .Halt => @panic("should not happen"),
            }
        }
    }
};
