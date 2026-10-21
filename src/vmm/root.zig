//! Virtual-machine policy and guest setup.

const utils = @import("utils");
const std = @import("std");
const kvm = @import("kvm");
const posix = std.posix;
const lazy = utils.Lazy.lazy;
const test_utils = @import("test_utils");
const image = @import("image/root.zig");
const VCpu = @import("vcpu.zig").VCpu;
const Epoll = utils.Epoll.Epoll;
const EpollEvent = utils.Epoll.Event;
const linux = std.os.linux;
const EventFd = utils.EventFd.EventFd;
const stat = @import("stat.zig");
const Statistics = stat.Statistics;
const io_worker = utils.IoWorker;
const Snapshot = @import("snapshot/root.zig").Snapshot;
const VmSnapshotState = @import("vm_snapshot.zig").VmSnapshotState;
const mmap = test_utils.mmap;

pub const VmSnapshot = Snapshot(VmSnapshotState);

pub const IoResult = kvm.IoResult;

const memory = @import("memory.zig");
const log = std.log.scoped(.vmm);

pub const arch = @import("arch/root.zig");

pub const MAX_VCPUS = 32;
pub var kvm_system = lazy(kvm.Kvm, kvm.Kvm.init);

const StopFlag = std.atomic.Value(bool);

pub const EventSource = enum(u2) {
    vcpu,
    io_bus,
    virtio,
    pci,
};

const EventToken = packed struct(io_worker.UserContext) {
    id: u10,
    ctx: u19,
    source: EventSource,
};

pub const DeviceConfig = struct {
    // Block device (path to the image)
    block_device: struct {
        path: []const u8 = "",
        async: bool = true,
    } = .{},

    // PCI support
    pci: bool = false,

    // Network support
    network: ?struct {
        mac: utils.Mac,
        iface: []const u8,
    } = null,
};

pub const VmConfig = struct {
    // Memory size (in bytes)
    ram_size: usize,

    // Main binary
    binary: []const u8,

    // Initramfs
    initramfs: ?[]const u8 = null,

    // Kernel cmdline
    cmdline: []const u8 = "",

    // Cpu count
    smp: u8 = 1,

    // Dump statistics at the end
    stat: bool = false,

    // Num worker threads
    worker_threads: usize = 4,

    // Device config
    device_config: DeviceConfig = .{},

    const Self = @This();

    fn verify(self: *const Self) !void {
        if (self.smp == 0 or self.smp > MAX_VCPUS) {
            return error.InvalidCpuCount;
        }
    }
};

pub const VmConsoleConfig = struct {
    input: ?std.Io.File = null,
    output: std.Io.File,
    index: u8,
    configure_terminal: bool = false,
};

const VmStateKind = enum(u8) {
    Initialized,
    Running,
    Stopped,
};

const VmState = struct {
    state: std.atomic.Value(VmStateKind) = std.atomic.Value(VmStateKind).init(.Initialized),
};

const INVALID_CPU: u32 = std.math.maxInt(u32);

pub const VmAction = enum(u32) {
    None,
    Stop,
    Snapshot,
};

pub const Vm = struct {
    vcpus: [MAX_VCPUS]?*VCpu = .{null} ** MAX_VCPUS,
    vcpus_count: usize = 0,
    io: std.Io,
    worker: *io_worker.IoWorker,
    state: VmState = .{},
    old_sigaction: posix.Sigaction,
    archvm: arch.ArchVm,
    statistics: Statistics = Statistics.new(),
    action: std.atomic.Value(VmAction) = .init(.None),
    dump_stat: bool = false,
    stop_event: std.Io.Event = .unset,

    const Self = @This();

    pub fn new(config: VmConfig, io: std.Io, allocator: std.mem.Allocator) !*Self {
        try config.verify();

        var archvm = try arch.ArchVm.new(config.ram_size, config.device_config.pci, allocator, io);
        var archvm_cleanup: ?*arch.ArchVm = &archvm;

        errdefer {
            if (archvm_cleanup) |a|
                a.deinit(allocator, io);
        }

        var self = try Self.empty(
            config.worker_threads,
            allocator,
            io,
        );

        self.archvm = archvm;
        errdefer self.deinit(allocator, io);
        archvm_cleanup = null;

        // Parse image (tho it should not write to memory, but it does for some reason)
        const img = try image.parse(config.binary, self.archvm.memory, &config);

        // Create BS cpu
        try self.create_vcpu(img.ep, 0, io, allocator);

        for (1..config.smp) |i| {
            try self.create_vcpu(0x0, @truncate(i), io, allocator);
        }

        // Setup all devices. Must be after vCPU setup, since it depends on cpu_count()
        try self.archvm.setup_devices(&config, self, allocator, io);

        // This writes cmdline, so it must be last
        try self.archvm.vm_prerun(self, config.cmdline, allocator);
        return self;
    }

    pub fn read_snapshot_file(
        path: []const u8,
        allocator: std.mem.Allocator,
        io: std.Io,
    ) !VmSnapshot {
        const file = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);

        const st = try file.stat(io);

        const buffer = try mmap.mmap(
            null,
            st.size,
            .{ .READ = true },
            .{ .TYPE = .SHARED },
            file.handle,
            0,
        );
        defer mmap.munmap(buffer);

        var reader = std.Io.Reader.fixed(buffer);
        return VmSnapshot.deserialize(&reader, allocator);
    }

    pub fn from_snapshot(
        snap: Snapshot(VmSnapshotState),
        device_config: DeviceConfig,
        allocator: std.mem.Allocator,
        io: std.Io,
    ) !*Self {
        var archvm = try arch.ArchVm.from_snapshot(
            &snap.data.arch_state,
            allocator,
            io,
        );
        errdefer archvm.deinit(allocator, io);

        var self = try Self.empty(
            1,
            allocator,
            io,
        );
        self.archvm = archvm;

        for (snap.data.snapshoted_memory()) |reg| {
            const slice = self.archvm.memory.as_slice(
                reg.start,
                reg.memory.len,
            ) orelse return error.InvalidSnapshot;

            @memcpy(slice, reg.memory);
        }

        for (snap.data.snapshoted_cpus(), 0..) |cpu, num| {
            try self.create_vcpu(0x0, @truncate(num), io, allocator);
            try self.vcpus[num].?.restore(cpu);
        }

        try self.archvm.device_bus.restore_devices(
            &snap.data.arch_state.device_bus,
            &device_config,
            self,
            allocator,
            io,
        );

        return self;
    }

    fn empty(
        worker_threads: usize,
        allocator: std.mem.Allocator,
        io: std.Io,
    ) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        // Setup signal handler for vCPU kick.
        const old = Self.setup_sighandler();
        errdefer Self.restore_sighandler(old);

        self.* = .{
            .io = io,
            .worker = try io_worker.IoWorker.new(
                worker_threads,
                .{ .f = Self.handler, .ctx = self },
                allocator,
                io,
            ),
            .old_sigaction = old,
            .archvm = undefined,
        };

        return self;
    }

    pub fn cpu_count(self: *const Self) usize {
        return self.vcpus_count;
    }

    pub fn stats(self: *Self) *Statistics {
        return &self.statistics;
    }

    // thread-unsafe
    pub fn attach_console(
        self: *Self,
        console: VmConsoleConfig,
        snap: ?VmSnapshot,
        alloc: std.mem.Allocator,
    ) !void {
        if (self.state.state.load(.monotonic) != .Initialized) {
            return error.InvalidState;
        }

        const state = if (snap) |*snapshot_state| &snapshot_state.data.arch_state else null;
        try self.archvm.attach_console(&console, self, state, alloc);
    }

    pub fn register_irq(self: *Self, eventfd: *const EventFd, num: u32) !void {
        try self.archvm.vm.register_irq(eventfd, num);
    }

    pub fn msi_signal(self: *const Self, address_lo: u32, address_hi: u32, data: u32) !void {
        try self.archvm.vm.msi_signal(address_lo, address_hi, data);
    }

    pub fn register_ioevent(
        self: *Self,
        eventfd: *const EventFd,
        address: u64,
        len: u32,
        datamatch: u64,
    ) !void {
        try self.archvm.vm.register_ioevent(eventfd, address, len, datamatch);
    }

    pub fn deinit(self: *Self, alloc: std.mem.Allocator, io: std.Io) void {
        // Destroy worker before VCPU
        self.worker.deinit(alloc, io);

        for (self.vcpus) |vcpu| {
            if (vcpu) |cpu|
                cpu.deinit(alloc, io);
        }

        if (self.dump_stat) {
            log.info("VMM Statistics:", .{});

            inline for (std.meta.fields(stat.StatKind)) |field| {
                const value: stat.StatKind = @enumFromInt(field.value);
                const name = @tagName(value);

                log.info("{s}: {d}", .{ name, self.statistics.read(value) });
            }
        }

        self.archvm.deinit(alloc, io);
        self.archvm.vm.deinit();
        self.archvm.memory.deinit(alloc);
        // Self.restore_sighandler(self.old_sigaction);
        alloc.destroy(self);
    }

    pub fn create_vcpu(
        self: *Self,
        ep: u64,
        id: u32,
        io: std.Io,
        alloc: std.mem.Allocator,
    ) !void {
        if (id >= MAX_VCPUS)
            return error.InvalidVcpuIndex;

        if (self.vcpus[id] != null)
            return error.VcpuAlreadyExists;

        self.vcpus[id] = try VCpu.new(self, id, ep, io, alloc);
        self.vcpus_count += 1;
    }

    fn wake_handler(_: std.posix.SIG) callconv(.c) void {}

    fn restore_sighandler(sa: std.posix.Sigaction) void {
        std.posix.sigaction(.USR1, &sa, null);
    }

    fn setup_sighandler() std.posix.Sigaction {
        var old: std.posix.Sigaction = undefined;
        const action = std.posix.Sigaction{
            .handler = .{ .handler = @alignCast(&wake_handler) },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };

        std.posix.sigaction(.USR1, &action, &old);
        return old;
    }

    pub fn stop_sync(self: *Vm, io: std.Io) !void {
        if (self.state.state.cmpxchgStrong(
            .Running,
            .Stopped,
            .monotonic,
            .monotonic,
        ) != null) {
            return error.InvalidState;
        }

        self.request_action(.Stop);
        try self.stop_event.wait(io);
    }

    pub fn stop_async(self: *Vm) !void {
        if (self.state.state.cmpxchgStrong(
            .Running,
            .Stopped,
            .monotonic,
            .monotonic,
        ) != null) {
            return error.InvalidState;
        }

        self.request_action(.Stop);
    }

    pub fn register_fd(
        self: *Self,
        fd: posix.fd_t,
        id: u10,
        ctx: u19,
        source: EventSource,
        edge: bool,
    ) !void {
        const token = EventToken{
            .id = id,
            .ctx = ctx,
            .source = source,
        };

        try self.worker.register_fd(fd, @bitCast(token), edge);
    }

    pub fn handler(ctx: *anyopaque, userctx: io_worker.UserContext) !void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const token: EventToken = @bitCast(userctx);

        switch (token.source) {
            .vcpu => {
                // Only abort when vCPU panicked
                if (try self.vcpus[token.id].?.ack_event() != .None) {
                    self.request_action(.Stop);
                }
            },
            .io_bus, .virtio, .pci => {
                try self.archvm.device_bus.handle_event(
                    token.source,
                    token.id,
                    token.ctx,
                    self.io,
                );
            },
        }
    }

    fn snapshot_unsafe(
        self: *Self,
        io: std.Io,
        allocator: std.mem.Allocator,
    ) !Snapshot(VmSnapshotState) {
        var snap = VmSnapshotState.new(try self.archvm.snapshot(self, allocator, io));
        errdefer snap.deinit(allocator);

        for (0..self.cpu_count()) |c| {
            const cpu = self.vcpus[c].?;

            try snap.snapshot_cpu(try cpu.snapshot(), allocator);
        }

        for (self.archvm.memory.get_regions()) |reg| {
            try snap.snapshot_memory(reg.gpa, reg.raw, allocator);
        }

        return Snapshot(VmSnapshotState).new(snap);
    }

    pub fn request_snapshot(self: *Self) void {
        self.request_action(.Snapshot);
    }

    pub fn snapshot(self: *Self, io: std.Io, allocator: std.mem.Allocator) !Snapshot(VmSnapshotState) {
        try self.stop_sync(io);
        return try self.snapshot_unsafe(io, allocator);
    }

    fn request_action(self: *Self, action: VmAction) void {
        _ = self.action.cmpxchgStrong(.None, action, .monotonic, .monotonic);

        _ = linux.futex(
            &self.action,
            .{ .private = true, .cmd = .WAKE },
            1,
            .{ .timeout = null },
            null,
            0,
        );
    }

    fn stop_internal(self: *Self, io: std.Io) !void {
        for (self.vcpus) |vcpu| {
            if (vcpu) |cpu| {
                cpu.stop();
                try cpu.wait_exit(io);
            }
        }

        self.worker.stop_and_join(io);
    }

    pub fn run(self: *Self, io: std.Io, alloc: std.mem.Allocator) !void {
        if (self.state.state.cmpxchgStrong(
            .Initialized,
            .Running,
            .monotonic,
            .monotonic,
        ) != null) {
            return error.AlreadyStarted;
        }

        for (self.vcpus, 0..) |vcpu, idx| {
            if (vcpu) |cpu| {
                try self.register_fd(cpu.eventfd.fd, @truncate(idx), 0, .vcpu, false);
                cpu.start(io);
            }
        }

        self.worker.start(io);

        while (self.action.load(.monotonic) == .None) {
            _ = linux.futex(
                &self.action,
                .{ .private = true, .cmd = .WAIT },
                @intFromEnum(VmAction.None),
                .{ .timeout = null },
                null,
                0,
            );
        }

        switch (self.action.load(.monotonic)) {
            .Stop => try self.stop_internal(io),
            .Snapshot => {
                try self.stop_internal(io);

                var snap = try self.snapshot_unsafe(io, alloc);
                defer snap.data.deinit(alloc);

                const file = try std.Io.Dir.cwd().createFile(io, "snapshot.zig", .{
                    .exclusive = true,
                });
                defer file.close(io);

                var buffer: [4096]u8 = undefined;
                var writer = file.writer(io, &buffer);

                try snap.serialize(&writer.interface);
                try writer.flush();
            },
            .None => @panic("Should not happen"),
        }

        self.state.state.store(.Stopped, .monotonic);
        self.stop_event.set(io);
    }
};

test {
    _ = @import("image/root.zig");
    _ = @import("io/root.zig");
    _ = @import("test.zig");
    _ = @import("snapshot/test.zig");
}
