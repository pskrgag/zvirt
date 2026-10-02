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
pub const IoResult = kvm.IoResult;

const memory = @import("memory.zig");
const log = std.log.scoped(.vmm);

pub const arch = @import("arch/root.zig");

const MAX_VCPUS = 32;
pub var kvm_system = lazy(kvm.Kvm, kvm.Kvm.init);

const StopFlag = std.atomic.Value(bool);

pub const EventSource = enum(u3) {
    vcpu,
    io_bus,
    virtio,
    pci,
};

const EventToken = packed struct(u64) {
    id: u10,
    ctx: u19,
    fd: posix.fd_t,
    source: EventSource,
};

pub const VmConfig = struct {
    // Memory size (in bytes)
    ram_size: usize,

    // Main binary
    binary: []const u8,

    // Initramfs
    initramfs: ?[]const u8 = null,

    // Block device (path to the image)
    block_device: struct {
        path: []const u8 = "",
        async: bool = true,
    } = .{},

    // Kernel cmdline
    cmdline: []const u8 = "",

    // Cpu count
    smp: u8 = 1,

    // PCI support
    pci: bool = false,

    // Network support
    network: ?struct {
        mac: utils.Mac,
        iface: []const u8,
    } = null,

    // Dump statistics at the end
    stat: bool = false,

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

pub const Vm = struct {
    vm: kvm.Vm,
    vcpus: [MAX_VCPUS]?*VCpu = .{null} ** MAX_VCPUS,
    vcpus_count: usize = 0,
    io: std.Io,
    config: VmConfig,
    memory: *memory.GuestMemory,
    epoll: Epoll,
    state: VmState = .{},
    old_sigaction: posix.Sigaction,
    archvm: arch.ArchVm,
    statistics: Statistics = Statistics.new(),

    const Self = @This();

    pub fn new(config: VmConfig, io: std.Io, allocator: std.mem.Allocator) !*Self {
        try config.verify();

        const system = try kvm_system.get();
        var self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        var vm = try system.create_vm();
        errdefer vm.deinit();

        try vm.create_irqchip();

        var mem = try memory.GuestMemory.new(allocator);
        errdefer mem.deinit(allocator);

        var archvm = try arch.ArchVm.new(&config, allocator, io);
        var archvm_cleanup = &archvm;
        errdefer archvm_cleanup.deinit(allocator, io);

        try archvm.setup_vm(&vm, mem, &config, allocator);
        const img = try image.parse(config.binary, mem, &config);

        for (mem.regions.items) |reg| {
            try vm.set_user_memory_region(reg.gpa, reg.slot, reg.raw);
        }

        const old = Self.setup_sighandler();
        errdefer Self.restore_sighandler(old);

        self.* = .{
            .vm = vm,
            .memory = mem,
            .io = io,
            .config = config,
            .epoll = try Epoll.new(),
            .old_sigaction = old,
            .archvm = archvm,
        };
        errdefer self.epoll.deinit();
        archvm_cleanup = &self.archvm;

        try self.archvm.setup_devices(&config, self, allocator, io);
        try self.create_vcpu(img.ep, 0, io, allocator);

        for (1..config.smp) |i| {
            try self.create_vcpu(0x0, @truncate(i), io, allocator);
        }

        return self;
    }

    pub fn stats(self: *Self) *Statistics {
        return &self.statistics;
    }

    // thread-unsafe
    pub fn attach_console(self: *Self, console: VmConsoleConfig) !void {
        if (self.state.state.load(.monotonic) != .Initialized)
            return error.InvalidState;

        try self.archvm.attach_console(&console, self);
    }

    pub fn register_irq(self: *Self, eventfd: *const EventFd, num: u32) !void {
        try self.vm.register_irq(eventfd, num);
    }

    pub fn msi_signal(self: *const Self, address_lo: u32, address_hi: u32, data: u32) !void {
        try self.vm.msi_signal(address_lo, address_hi, data);
    }

    pub fn register_ioevent(
        self: *Self,
        eventfd: *const EventFd,
        address: u64,
        len: u32,
        datamatch: u64,
    ) !void {
        try self.vm.register_ioevent(eventfd, address, len, datamatch);
    }

    pub fn deinit(self: *Self, alloc: std.mem.Allocator, io: std.Io) void {
        for (self.vcpus) |vcpu| {
            if (vcpu) |cpu|
                cpu.deinit(alloc, io);
        }

        if (self.config.stat) {
            log.info("VMM Statistics:\n", .{});

            inline for (std.meta.fields(stat.StatKind)) |field| {
                const value: stat.StatKind = @enumFromInt(field.value);
                const name = @tagName(value);

                std.debug.print("{s}: {d}\n", .{ name, self.statistics.read(value) });
            }
        }

        self.epoll.deinit();
        self.archvm.deinit(alloc, io);
        self.vm.deinit();
        self.memory.deinit(alloc);
        Self.restore_sighandler(self.old_sigaction);
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

    pub fn stop(self: *Vm) !void {
        if (self.state.state.cmpxchgStrong(
            .Running,
            .Stopped,
            .monotonic,
            .monotonic,
        ) != null) {
            return error.InvalidState;
        }

        for (self.vcpus) |vcpu| {
            if (vcpu) |cpu|
                cpu.stop();
        }
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
            .fd = fd,
            .source = source,
        };
        const flags = linux.EPOLL.IN | if (edge) linux.EPOLL.ET else 0;

        try self.epoll.add_with_events(fd, flags, @bitCast(token));
    }

    pub fn run(self: *Self, alloc: std.mem.Allocator, io: std.Io) !void {
        if (self.state.state.cmpxchgStrong(
            .Initialized,
            .Running,
            .monotonic,
            .monotonic,
        ) != null) {
            return error.AlreadyStarted;
        }

        try self.archvm.vm_prerun(self, self.config.cmdline, alloc);

        for (self.vcpus, 0..) |vcpu, idx| {
            if (vcpu) |cpu| {
                try self.register_fd(cpu.eventfd.fd, @truncate(idx), 0, .vcpu, false);
                cpu.start(io);
            }
        }

        var panic_cpu: ?u64 = null;

        while (true) {
            var event_buffer: [1024]EpollEvent = undefined;

            const events = self.epoll.pwait(&event_buffer, -1, linux.sigfillset()) catch |e| {
                if (e == error.Interrupted)
                    continue;

                return e;
            };

            for (events) |event| {
                const token: EventToken = @bitCast(event.data);

                switch (token.source) {
                    .vcpu => {
                        const eventfd = EventFd{ .fd = @intCast(token.fd) };

                        // Read anyway to avoid hitting the same event.
                        _ = try eventfd.read();

                        // Only abort when vCPU panicked
                        if (self.vcpus[token.id].?.get_exit_reason() != .None) {
                            panic_cpu = token.id;
                            break;
                        }
                    },
                    .io_bus, .virtio, .pci => {
                        try self.archvm.device_bus.handle_event(
                            token.source,
                            token.id,
                            token.ctx,
                            token.fd,
                            io,
                        );
                    },
                }
            }

            if (panic_cpu) |pcpu| {
                log.info("vCPU {} requested stop. Stopping the guest\n", .{pcpu});

                for (self.vcpus, 0..) |vcpu, idx| {
                    if (vcpu) |cpu| {
                        if (idx != pcpu) {
                            cpu.stop();
                        }
                    }
                }

                break;
            }
        }

        self.state.state.store(.Stopped, .monotonic);
    }
};

test {
    _ = @import("image/root.zig");
    _ = @import("io/root.zig");
    _ = @import("test.zig");
}
