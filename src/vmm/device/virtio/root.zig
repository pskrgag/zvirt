//! Virtio MMIO device

const std = @import("std");
const Block = @import("block.zig").Block;

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
};

pub const VirtioDeviceType = enum(u32) {
    BlockDevice = Block.TYPE,
};

const StatusBits = enum(u32) {
    Ack = 1 << 0,
    Driver = 1 << 1,
    DriverOk = 1 << 2,
    FeatureOk = 1 << 3,
    DeviceNeedsReset = 1 << 6,
    Failed = 1 << 7,
};

const VIRTIO_F_VERSION_1: u64 = 1 << 32;
const Status = u32;

const MAX_QUEUES_SUPPORTED = 1;
const MAX_QUEUE_ELEMENTS = 256;

fn set_low(value: *u64, low: u32) void {
    value.* = (value.* & 0xffff_ffff_0000_0000) | @as(u64, low);
}

fn set_high(value: *u64, high: u32) void {
    value.* = (value.* & 0x0000_0000_ffff_ffff) |
        (@as(u64, high) << 32);
}

const VirtQueue = struct {
    ready: u32 = 0,
    elements: u32 = MAX_QUEUE_ELEMENTS,

    // Invalid PA
    //
    // TODO: introduce PA abstraction one day...
    pa: u64 = std.math.maxInt(u64),
    available_ring: u64 = std.math.maxInt(u64),
    used_ring: u64 = std.math.maxInt(u64),
};

pub fn VirtioMmio(comptime Device: type) type {
    return struct {
        // Assuming page size
        base: u64,
        // TODO: allocate IRQ properly
        irq: u64 = 5,
        device: Device,
        status: Status = 0,
        device_sel: bool = false,
        driver_sel: bool = false,
        device_features: u64 = Device.features() | VIRTIO_F_VERSION_1,
        driver_features: u64 = 0,
        queue_sel: u32 = 0,
        virt_queues: [MAX_QUEUES_SUPPORTED]VirtQueue =
            .{VirtQueue{}} ** MAX_QUEUES_SUPPORTED,

        const Self = @This();

        fn queue_num_max(self: *const Self) u32 {
            return if (self.queue_sel < MAX_QUEUES_SUPPORTED)
                MAX_QUEUE_ELEMENTS
            else
                0;
        }

        fn get_queue_ready(self: *const Self) u32 {
            return if (self.queue_sel < MAX_QUEUES_SUPPORTED)
                self.virt_queues[self.queue_sel].ready
            else
                0;
        }

        fn set_queue_ready(self: *Self, val: u32) void {
            if (self.queue_sel < MAX_QUEUES_SUPPORTED)
                self.virt_queues[self.queue_sel].ready = val;
        }

        fn set_queue_num(self: *Self, val: u32) void {
            if (self.queue_sel < MAX_QUEUES_SUPPORTED and val <= MAX_QUEUE_ELEMENTS and std.math.isPowerOfTwo(val))
                self.virt_queues[self.queue_sel].elements = val;
        }

        fn set_queue_desc_low(self: *Self, val: u32) void {
            if (self.queue_sel < MAX_QUEUES_SUPPORTED)
                set_low(&self.virt_queues[self.queue_sel].pa, val);
        }

        fn set_queue_desc_high(self: *Self, val: u32) void {
            if (self.queue_sel < MAX_QUEUES_SUPPORTED)
                set_high(&self.virt_queues[self.queue_sel].pa, val);
        }

        fn set_queue_avail_low(self: *Self, val: u32) void {
            if (self.queue_sel < MAX_QUEUES_SUPPORTED)
                set_low(&self.virt_queues[self.queue_sel].available_ring, val);
        }

        fn set_queue_avail_high(self: *Self, val: u32) void {
            if (self.queue_sel < MAX_QUEUES_SUPPORTED)
                set_high(&self.virt_queues[self.queue_sel].available_ring, val);
        }

        fn set_queue_used_low(self: *Self, val: u32) void {
            if (self.queue_sel < MAX_QUEUES_SUPPORTED)
                set_low(&self.virt_queues[self.queue_sel].used_ring, val);
        }

        fn set_queue_used_high(self: *Self, val: u32) void {
            if (self.queue_sel < MAX_QUEUES_SUPPORTED)
                set_high(&self.virt_queues[self.queue_sel].used_ring, val);
        }

        pub fn new(base: u64, device: Device) Self {
            // TODO: replace all 4096 with arch page size
            std.debug.assert(std.mem.isAligned(base, 4096));

            return .{
                .base = base,
                .irq = 5,
                .device = device,
            };
        }

        fn update_status(self: *Self, bit: StatusBits, set: bool) void {
            if (set) {
                self.status |= @intFromEnum(bit);
            } else {
                self.status &= ~@intFromEnum(bit);
            }
        }

        pub fn handle_read(self: *Self, reg_raw: u32) u32 {
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

                    // W only register
                    .DeviceFeaturesSel,
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
                    => 0,
                };
            } else if (reg_raw >= 0x100) {
                return self.device.read_config(reg_raw - 0x100);
            } else {
                @panic("todo");
            }
        }

        pub fn handle_write(self: *Self, reg_raw: u32, data: u32) void {
            if (std.enums.fromInt(MmioRegister, reg_raw)) |reg| {
                switch (reg) {
                    // Read only registers
                    .Magic,
                    .Version,
                    .DeviceType,
                    .VendorId,
                    .DeviceFeatures,
                    .QueueNumMax,
                    => {},

                    .Status => self.status = data,
                    .DeviceFeaturesSel => self.device_sel = data != 0,
                    .DriverFeaturesSel => self.driver_sel = data != 0,
                    .QueueReady => self.set_queue_ready(data),
                    .QueueNum => self.set_queue_num(data),
                    .QueueDescLow => self.set_queue_desc_low(data),
                    .QueueDescHigh => self.set_queue_desc_high(data),
                    .QueueAvailLow => self.set_queue_avail_low(data),
                    .QueueAvailHigh => self.set_queue_avail_high(data),
                    .QueueUsedLow => self.set_queue_used_low(data),
                    .QueueUsedHigh => self.set_queue_used_high(data),
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
    };
}

pub const VirtioDevice = union(enum) {
    block: VirtioMmio(Block),

    const Self = @This();

    pub const Register = MmioRegister;
    pub const DeviceType = VirtioDeviceType;

    pub fn new(base_address: u64, kind: DeviceType) Self {
        return switch (kind) {
            .BlockDevice => .{ .block = VirtioMmio(Block).new(base_address, .{}) },
        };
    }

    pub fn base(self: *const Self) u64 {
        return switch (self.*) {
            inline else => |*device| device.base,
        };
    }

    pub fn irq(self: *const Self) u64 {
        return switch (self.*) {
            inline else => |*device| device.irq,
        };
    }

    pub fn handle_read(self: *Self, reg_raw: u32) u32 {
        return switch (self.*) {
            inline else => |*device| device.handle_read(reg_raw),
        };
    }

    pub fn handle_write(self: *Self, reg_raw: u32, data: u32) void {
        return switch (self.*) {
            inline else => |*device| device.handle_write(reg_raw, data),
        };
    }
};
