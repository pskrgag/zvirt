//! Virtio MMIO device

const std = @import("std");
const Block = @import("block.zig").Block;
const VirtQueue = @import("queue.zig").VirtQueue;
const MAX_QUEUE_ELEMENTS = @import("queue.zig").MAX_QUEUE_ELEMENTS;
const Vm = @import("../../root.zig").Vm;
const Mutex = std.Io.Mutex;
const utils = @import("utils");
const EventFd = utils.EventFd.EventFd;

const log = std.log.scoped(.virtio);

pub const MmioRegister = enum(u64) {
    Magic = 0x0,
    Version = 0x4,
    DeviceType = 0x8,
    VendorId = 0xc,
    Status = 0x70,
    DeviceFeaturesSel = 0x14,
    DeviceFeatures = 0x10,
    DriverFeaturesSel = 0x24,
    DriverFeatures = 0x20,
    QueueNumMax = 0x34,
    QueueSel = 0x30,
    QueueReady = 0x44,
    QueueNum = 0x38,
    QueueDescLow = 0x80,
    QueueDescHigh = 0x84,
    QueueAvailLow = 0x90,
    QueueAvailHigh = 0x94,
    QueueUsedLow = 0xa0,
    QueueUsedHigh = 0xa4,
    QueueNotify = 0x50,
    ConfigGeneration = 0xfc,
    InterruptStatus = 0x60,
    InterruptAck = 0x64,
};

pub const VirtioDeviceType = enum(u32) {
    BlockDevice = Block.TYPE,
};

pub const VirtioDeviceInit = union(VirtioDeviceType) {
    BlockDevice: []const u8,
};

const StatusBits = enum(u32) {
    Ack = 1 << 0,
    Driver = 1 << 1,
    DriverOk = 1 << 2,
    FeatureOk = 1 << 3,
    DeviceNeedsReset = 1 << 6,
    Failed = 1 << 7,
};

const VIRTIO_IRQ_USED_RING: u32 = 1 << 0;
const VIRTIO_IRQ_CONFIG_CHANGE: u32 = 1 << 1;

const VIRTIO_F_VERSION_1: u64 = 1 << 32;
const Status = u32;

const MAX_QUEUES_SUPPORTED = 1;

fn set_low(value: *u64, low: u32) void {
    value.* = (value.* & 0xffff_ffff_0000_0000) | @as(u64, low);
}

fn set_high(value: *u64, high: u32) void {
    value.* = (value.* & 0x0000_0000_ffff_ffff) |
        (@as(u64, high) << 32);
}

pub fn VirtioMmio(comptime Device: type) type {
    return struct {
        // Assuming page size
        base: u64,
        irq: u32,
        device: Device,
        status: Status = 0,
        device_sel: bool = false,
        driver_sel: bool = false,
        device_features: u64 = Device.features() | VIRTIO_F_VERSION_1,
        driver_features: u64 = 0,
        queue_sel: u32 = 0,
        virt_queues: [MAX_QUEUES_SUPPORTED]VirtQueue =
            .{VirtQueue{}} ** MAX_QUEUES_SUPPORTED,
        vm: *Vm,
        irq_state: u32 = 0,
        alloc: std.heap.ArenaAllocator,
        mutex: Mutex = Mutex.init,
        irqfd: EventFd,
        notifyfds: [MAX_QUEUES_SUPPORTED]EventFd = undefined,

        const Self = @This();

        fn queue_num_max(self: *const Self) u32 {
            return if (self.queue_sel < self.device.max_queues())
                MAX_QUEUE_ELEMENTS
            else
                0;
        }

        fn get_queue_ready(self: *const Self) u32 {
            return if (self.queue_sel < self.device.max_queues())
                self.virt_queues[self.queue_sel].is_ready
            else
                0;
        }

        fn set_queue_ready(self: *Self, val: u32) !void {
            if (self.queue_sel < self.device.max_queues())
                try self.virt_queues[self.queue_sel].ready(self.vm.memory, val);
        }

        fn set_queue_num(self: *Self, val: u32) void {
            if (self.queue_sel < self.device.max_queues() and val <= MAX_QUEUE_ELEMENTS and std.math.isPowerOfTwo(val))
                self.virt_queues[self.queue_sel].elements = val;
        }

        fn set_queue_desc_low(self: *Self, val: u32) void {
            if (self.queue_sel < self.device.max_queues())
                set_low(&self.virt_queues[self.queue_sel].desc_ring, val);
        }

        fn set_queue_desc_high(self: *Self, val: u32) void {
            if (self.queue_sel < self.device.max_queues())
                set_high(&self.virt_queues[self.queue_sel].desc_ring, val);
        }

        fn set_queue_avail_low(self: *Self, val: u32) void {
            if (self.queue_sel < self.device.max_queues())
                set_low(&self.virt_queues[self.queue_sel].available_ring, val);
        }

        fn set_queue_avail_high(self: *Self, val: u32) void {
            if (self.queue_sel < self.device.max_queues())
                set_high(&self.virt_queues[self.queue_sel].available_ring, val);
        }

        fn set_queue_used_low(self: *Self, val: u32) void {
            if (self.queue_sel < self.device.max_queues())
                set_low(&self.virt_queues[self.queue_sel].used_ring, val);
        }

        fn set_queue_used_high(self: *Self, val: u32) void {
            if (self.queue_sel < self.device.max_queues())
                set_high(&self.virt_queues[self.queue_sel].used_ring, val);
        }

        fn notify_queue(self: *Self, idx: usize, io: std.Io) !void {
            if (idx < self.device.max_queues()) {
                var reqs = try self.virt_queues[idx].kick(
                    self.vm.memory,
                    self.alloc.allocator(),
                );
                defer _ = self.alloc.reset(.retain_capacity);
                defer reqs.deinit(self.alloc.allocator());

                self.device.proccess_requests(reqs.items, io) catch {
                    @panic("todo");
                };

                var completed: usize = 0;

                for (reqs.items) |req| {
                    // Len == 0 means that request will be handled in async
                    if (req.len != 0) {
                        const res = self.virt_queues[idx].push_used(
                            req.head,
                            req.len,
                        );
                        std.debug.assert(res);

                        completed += 1;
                    }
                }

                if (completed != 0) {
                    self.irq_state |= VIRTIO_IRQ_USED_RING;
                    try self.irqfd.notify();
                }
            }
        }

        pub fn new(base: u64, device: Device, vm: *Vm, irq: u32, alloc: std.mem.Allocator) !Self {
            // TODO: replace all 4096 with arch page size
            std.debug.assert(std.mem.isAligned(base, 4096));
            std.debug.assert(MAX_QUEUES_SUPPORTED >= device.max_queues());

            var irqfd = try EventFd.new(1);
            errdefer irqfd.deinit();

            try vm.register_irq(&irqfd, irq);

            var notifyfds: [MAX_QUEUES_SUPPORTED]EventFd = undefined;
            var notifyfd_count: usize = 0;

            errdefer for (notifyfds[0..notifyfd_count]) |*notifyfd| {
                notifyfd.deinit();
            };

            while (notifyfd_count < device.max_queues()) {
                notifyfds[notifyfd_count] = try EventFd.new(0);
                notifyfd_count += 1;
            }

            return .{
                .irqfd = irqfd,
                .notifyfds = notifyfds,
                .base = base,
                .irq = irq,
                .device = device,
                .vm = vm,
                .alloc = std.heap.ArenaAllocator.init(alloc),
            };
        }

        fn update_status(self: *Self, bit: StatusBits, set: bool) void {
            if (set) {
                self.status |= @intFromEnum(bit);
            } else {
                self.status &= ~@intFromEnum(bit);
            }
        }

        pub fn handle_read(self: *Self, reg_raw: u32, io: std.Io) !u32 {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);

            if (std.enums.fromInt(MmioRegister, reg_raw)) |reg| {
                return switch (reg) {
                    .Magic => 0x74726976,
                    .Version => 0x2,
                    .DeviceType => Device.TYPE,
                    .VendorId => 0x1AF4,
                    .Status => self.status,
                    .QueueNumMax => self.queue_num_max(),
                    .QueueReady => self.get_queue_ready(),
                    .DeviceFeatures => if (self.device_sel)
                        @truncate(self.device_features >> 32)
                    else
                        @truncate(self.device_features),

                    // Not sure if config will change. Keep as 0 for now
                    .ConfigGeneration => 0,
                    .InterruptStatus => self.irq_state,

                    // W only register
                    .DeviceFeaturesSel,
                    .InterruptAck,
                    .DriverFeaturesSel,
                    .DriverFeatures,
                    .QueueSel,
                    .QueueNum,
                    .QueueDescLow,
                    .QueueDescHigh,
                    .QueueAvailLow,
                    .QueueAvailHigh,
                    .QueueUsedLow,
                    .QueueUsedHigh,
                    .QueueNotify,
                    => 0,
                };
            } else if (reg_raw >= 0x100) {
                return self.device.read_config(reg_raw - 0x100);
            } else {
                @panic("todo");
            }
        }

        pub fn handle_write(self: *Self, reg_raw: u32, data: u32, io: std.Io) !void {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);

            if (std.enums.fromInt(MmioRegister, reg_raw)) |reg| {
                switch (reg) {
                    // Read only registers
                    .Magic,
                    .Version,
                    .DeviceType,
                    .VendorId,
                    .DeviceFeatures,
                    .QueueNumMax,
                    .ConfigGeneration,
                    .InterruptStatus,
                    => {},

                    .Status => self.status = data,
                    .InterruptAck => {
                        self.irq_state &= ~data;
                    },
                    .DeviceFeaturesSel => self.device_sel = data != 0,
                    .DriverFeaturesSel => self.driver_sel = data != 0,
                    .QueueReady => try self.set_queue_ready(data),
                    .QueueNum => self.set_queue_num(data),
                    .QueueDescLow => self.set_queue_desc_low(data),
                    .QueueDescHigh => self.set_queue_desc_high(data),
                    .QueueAvailLow => self.set_queue_avail_low(data),
                    .QueueAvailHigh => self.set_queue_avail_high(data),
                    .QueueUsedLow => self.set_queue_used_low(data),
                    .QueueUsedHigh => self.set_queue_used_high(data),
                    .QueueNotify => try self.notify_queue(data, io),
                    .DriverFeatures => {
                        if (self.driver_sel)
                            set_high(&self.driver_features, data)
                        else
                            set_low(&self.driver_features, data);

                        self.update_status(
                            .FeatureOk,
                            (self.driver_features & ~self.device_features) == 0,
                        );
                    },
                    .QueueSel => self.queue_sel = data,
                }
            } else if (reg_raw >= 0x100) {
                @panic("todo");
                // self.device.read_config(reg_raw - 0x100);
            } else {
                @panic("todo");
            }
        }

        fn handle_completion_event(self: *Self) !void {
            try self.device.ack_event();

            var consumed = false;
            var batch: usize = 0;

            while (try self.device.pop_completion()) |async_result| {
                const res = self.virt_queues[0].push_used(
                    async_result.head,
                    async_result.len,
                );
                std.debug.assert(res);

                batch += 1;
                consumed = true;
            }

            if (consumed) {
                log.debug("batched {}\n", .{batch});
                self.irq_state |= VIRTIO_IRQ_USED_RING;
                try self.irqfd.notify();
            }
        }

        pub fn register_events(self: *const Self, vm: *Vm, id: u29) !void {
            try vm.register_fd(self.device.event_source(), id, .virtio);

            for (self.notifyfds[0..self.device.max_queues()], 0..) |notifyfd, queue_idx| {
                try vm.register_ioevent(
                    &notifyfd,
                    self.base + @intFromEnum(MmioRegister.QueueNotify),
                    @sizeOf(u32),
                    queue_idx,
                );

                try vm.register_fd(notifyfd.as_fd(), id, .virtio);
            }
        }

        pub fn handle_event(self: *Self, fd: std.posix.fd_t, io: std.Io) !void {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);

            if (fd == self.device.event_source()) {
                try self.handle_completion_event();
                return;
            }

            for (self.notifyfds[0..self.device.max_queues()], 0..) |notifyfd, queue_idx| {
                if (notifyfd.as_fd() == fd) {
                    _ = try notifyfd.read();
                    try self.notify_queue(queue_idx, io);
                    return;
                }
            }

            return error.UnknownNotifyEvent;
        }

        pub fn deinit(self: *Self, io: std.Io) void {
            for (self.notifyfds[0..self.device.max_queues()]) |*notifyfd| {
                notifyfd.deinit();
            }

            self.irqfd.deinit();
            self.device.deinit(io);
            self.alloc.deinit();
        }
    };
}

pub const VirtioDevice = union(enum) {
    block: VirtioMmio(Block),

    const Self = @This();

    pub const Register = MmioRegister;
    pub const DeviceType = VirtioDeviceInit;

    pub fn new(
        base_address: u64,
        kind: VirtioDeviceInit,
        vm: *Vm,
        irq_num: u32,
        alloc: std.mem.Allocator,
        io: std.Io,
    ) !Self {
        return switch (kind) {
            .BlockDevice => |path| .{
                .block = try VirtioMmio(Block).new(
                    base_address,
                    try Block.new(path, io),
                    vm,
                    irq_num,
                    alloc,
                ),
            },
        };
    }

    pub fn handle_event(self: *Self, fd: std.posix.fd_t, io: std.Io) !void {
        return switch (self.*) {
            inline else => |*device| device.handle_event(fd, io),
        };
    }

    pub fn register_events(self: *const Self, vm: *Vm, id: u29) !void {
        return switch (self.*) {
            inline else => |*device| device.register_events(vm, id),
        };
    }

    pub fn base(self: *const Self) u64 {
        return switch (self.*) {
            inline else => |*device| device.base,
        };
    }

    pub fn irq(self: *const Self) u32 {
        return switch (self.*) {
            inline else => |*device| device.irq,
        };
    }

    pub fn handle_read(self: *Self, reg_raw: u32, io: std.Io) !u32 {
        return switch (self.*) {
            inline else => |*device| device.handle_read(reg_raw, io),
        };
    }

    pub fn handle_write(self: *Self, reg_raw: u32, data: u32, io: std.Io) !void {
        return switch (self.*) {
            inline else => |*device| device.handle_write(reg_raw, data, io),
        };
    }

    pub fn deinit(self: *Self, io: std.Io) void {
        return switch (self.*) {
            inline else => |*device| device.deinit(io),
        };
    }
};
