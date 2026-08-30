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

pub const VCpuExitReason = enum(u8) {
    Shutdown,
    UnhandledException,
    TestExit,
    Aborted,
    InternalError,
    None,
};

const ExitReason = std.atomic.Value(VCpuExitReason);

pub const VCpu = struct {
    cpu: kvm.Vcpu,
    num: usize,
    vm: *Vm,
    thread: std.Thread = undefined,
    start_event: Event = .unset,
    stop_flag: StopFlag = StopFlag.init(false),
    eventfd: EventFd,
    exit_reason: ExitReason = ExitReason.init(.None),

    const Self = @This();

    pub fn new(vm: *Vm, num: usize, ep: u64, io: std.Io, alloc: std.mem.Allocator) !*Self {
        var c = try vm.vm.create_vcpu(num);
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

        try arch.setup_vcpu(&c, ep);

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

    pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
        self.stop();
        self.thread.join();
        self.eventfd.deinit();

        self.cpu.deinit();
        alloc.destroy(self);
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
            self.eventfd.notify() catch @panic("no idea how to handle it");
        }

        while (!self.stop_flag.load(.monotonic)) {
            self.cpu.run_once(result) catch |e| {
                if (e != error.Interrupted)
                    return e;

                // Continue the loop. If it was stop signal, stop_flag would be set.
                continue;
            };

            const reason = try self.cpu.exit_reason();
            switch (reason) {
                .Io => |io_req| {
                    // Detecting write to fake port, which indicates test exit
                    if (try self.vm.device_bus.handle_io(io_req, self.vm, io)) {
                        self.exit_reason.store(.TestExit, .monotonic);
                        break;
                    }
                },
                .Shutdown => {
                    self.exit_reason.store(.Shutdown, .monotonic);
                    break;
                },
                .Mmio => |mmio| {
                    result = try self.vm.device_bus.handle_mmio(mmio, io);
                },
                .Interrupted => {},
                .Halt => @panic("should not happen"),
            }
        }
    }
};
