//! Virtio MMIO transport

const std = @import("std");
const Block = @import("block.zig").Block;
const Net = @import("net.zig").Net;
const virtio = @import("root.zig");
const VirtioCore = virtio.VirtioCore;
const VirtioDeviceInit = virtio.VirtioDeviceInit;
const MAX_QUEUES_SUPPORTED = virtio.MAX_QUEUES_SUPPORTED;
const MAX_QUEUE_ELEMENTS = @import("queue.zig").MAX_QUEUE_ELEMENTS;
const Vm = @import("../../root.zig").Vm;
const Mutex = std.Io.Mutex;
const utils = @import("utils");
const EventFd = utils.EventFd.EventFd;
const MmioDevice = @import("../root.zig").MmioDevice;

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

const VIRTIO_IRQ_USED_RING: u32 = 1 << 0;
const VIRTIO_IRQ_CONFIG_CHANGE: u32 = 1 << 1;

pub fn VirtioMmio(comptime Device: type) type {
    return struct {
        // Assuming page size
        base: u64,
        irq: u32,
        device: Device,
        device_sel: bool = false,
        driver_sel: bool = false,
        queue_sel: u32 = 0,
        vm: *Vm,
        irq_state: u32 = 0,
        mutex: Mutex = Mutex.init,
        irqfd: EventFd,

        const Self = @This();

        fn queue_num_max(self: *const Self) u32 {
            return if (self.queue_sel < self.device.core.max_queues())
                MAX_QUEUE_ELEMENTS
            else
                0;
        }

        pub fn new(base: u64, device: Device, vm: *Vm, irq: u32) !Self {
            // TODO: replace all 4096 with arch page size
            std.debug.assert(std.mem.isAligned(base, 4096));

            var irqfd = try EventFd.new(1);
            errdefer irqfd.deinit();

            try vm.register_irq(&irqfd, irq);

            return .{
                .irqfd = irqfd,
                .base = base,
                .irq = irq,
                .device = device,
                .vm = vm,
            };
        }

        pub fn handle_read(self: *Self, reg_raw: u32, io: std.Io) !u32 {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);

            if (std.enums.fromInt(MmioRegister, reg_raw)) |reg| {
                return switch (reg) {
                    .Magic => 0x74726976,
                    .Version => 0x2,
                    .DeviceType => Device.MMIO_TYPE,
                    .VendorId => 0x1AF4,
                    .Status => self.device.core.status,
                    .QueueNumMax => self.queue_num_max(),
                    .QueueReady => try self.device.core.get_queue_ready(self.queue_sel, io),
                    .DeviceFeatures => if (self.device_sel)
                        @truncate(self.device.core.device_features >> 32)
                    else
                        @truncate(self.device.core.device_features),

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

                    .Status => self.device.core.status = @truncate(data),
                    .InterruptAck => {
                        self.irq_state &= ~data;
                    },
                    .DeviceFeaturesSel => self.device_sel = data != 0,
                    .DriverFeaturesSel => self.driver_sel = data != 0,
                    .QueueReady => try self.device.core.set_queue_ready(self.queue_sel, self.vm.memory, data, io),
                    .QueueNum => try self.device.core.set_queue_num(self.queue_sel, data, io),
                    .QueueDescLow => try self.device.core.set_queue_desc_low(self.queue_sel, data, io),
                    .QueueDescHigh => try self.device.core.set_queue_desc_high(self.queue_sel, data, io),
                    .QueueAvailLow => try self.device.core.set_queue_avail_low(self.queue_sel, data, io),
                    .QueueAvailHigh => try self.device.core.set_queue_avail_high(self.queue_sel, data, io),
                    .QueueUsedLow => try self.device.core.set_queue_used_low(self.queue_sel, data, io),
                    .QueueUsedHigh => try self.device.core.set_queue_used_high(self.queue_sel, data, io),
                    .DriverFeatures => self.device.core.update_driver_feats(data, self.driver_sel),
                    .QueueSel => self.queue_sel = data,
                    else => {},
                }
            } else if (reg_raw >= 0x100) {
                @panic("todo");
                // self.device.read_config(reg_raw - 0x100);
            } else {
                @panic("todo");
            }
        }

        fn handle_completion_event(self: *Self, io: std.Io) !void {
            const completed = try self.device.handle_completion_event(io);

            if (completed) {
                self.irq_state |= VIRTIO_IRQ_USED_RING;
                try self.irqfd.notify();
            }
        }

        pub fn register_events(self: *const Self, vm: *Vm, id: u29) !void {
            if (self.device.completion_event_source()) |event|
                try vm.register_fd(event, id, .virtio);

            for (0..self.device.core.max_queues()) |queue_idx| {
                const notifyfd = self.device.core.notifyfd_for_queue(queue_idx) catch @panic("should not happen");

                try vm.register_ioevent(
                    notifyfd,
                    self.base + @intFromEnum(MmioRegister.QueueNotify),
                    @sizeOf(u32),
                    queue_idx,
                );

                try vm.register_fd(notifyfd.as_fd(), id, .virtio);
            }
        }

        pub fn handle_event(self: *Self, fd: std.posix.fd_t, io: std.Io) !void {
            {
                if (fd == self.device.completion_event_source()) {
                    // Don't take the mutex on hot path. Keep it under that if.
                    try self.mutex.lock(io);
                    defer self.mutex.unlock(io);

                    try self.handle_completion_event(io);
                    return;
                }
            }

            const res = try self.device.handle_notify(fd, self.vm, io);
            if (res.proccessed) {
                try self.mutex.lock(io);
                defer self.mutex.unlock(io);

                self.irq_state |= VIRTIO_IRQ_USED_RING;
                try self.irqfd.notify();
            }
        }

        pub fn deinit(self: *Self, io: std.Io) void {
            self.irqfd.deinit();
            self.device.deinit(io);
        }
    };
}

pub const VirtioMmioDevice = union(enum) {
    block: VirtioMmio(Block),
    net: VirtioMmio(Net),

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
            .BlockDevice => |block| .{ .block = blk: {
                const num_queues = if (block.async)
                    1
                else
                    vm.config.smp;

                break :blk try VirtioMmio(Block).new(
                    base_address,
                    try Block.new(block.path, num_queues, block.async, alloc, io),
                    vm,
                    irq_num,
                );
            } },
            .NetDevice => |net| .{ .net = try VirtioMmio(Net).new(
                base_address,
                try Net.new(net.mac, net.iface, alloc),
                vm,
                irq_num,
            ) },
        };
    }

    fn validate_mmio_access(offset: usize, size: usize) !void {
        // All registers in generic space are u32. Device config space can be accessed in any way.
        if (offset < 0x100 and size != @sizeOf(u32))
            return error.InvalidMmioAccessSize;

        if (!std.math.isPowerOfTwo(size))
            return error.InvalidMmioAccessSize;

        // Tho it's supported, but it's not atomic. Let's disable for now and see if linux will
        // complain.
        if (size >= @sizeOf(u64))
            return error.InvalidMmioAccessSize;
    }

    fn mmio_read(context: *anyopaque, offset: usize, data: []u8, io: std.Io) !void {
        try validate_mmio_access(offset, data.len);

        const self: *Self = @ptrCast(@alignCast(context));
        const value = try self.handle_read(@intCast(offset), io);

        switch (data.len) {
            @sizeOf(u8) => data[0] = @truncate(value),
            @sizeOf(u16) => std.mem.writeInt(u16, data[0..@sizeOf(u16)], @truncate(value), .little),
            @sizeOf(u32) => std.mem.writeInt(u32, data[0..@sizeOf(u32)], value, .little),
            else => unreachable,
        }
    }

    fn mmio_write(context: *anyopaque, offset: usize, data: []const u8, io: std.Io) !void {
        try validate_mmio_access(offset, data.len);

        const self: *Self = @ptrCast(@alignCast(context));
        const value: u32 = switch (data.len) {
            @sizeOf(u8) => data[0],
            @sizeOf(u16) => std.mem.readInt(u16, data[0..@sizeOf(u16)], .little),
            @sizeOf(u32) => std.mem.readInt(u32, data[0..@sizeOf(u32)], .little),
            else => unreachable,
        };

        try self.handle_write(@intCast(offset), value, io);
    }

    pub fn mmio_device(self: *Self) MmioDevice {
        return MmioDevice{
            .context = self,
            .read_fn = mmio_read,
            .write_fn = mmio_write,
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
