//! PCI virtio device

const std = @import("std");
const virtio = @import("root.zig");
const VirtioCore = virtio.VirtioCore;
const VirtioDeviceInit = virtio.VirtioDeviceInit;
const pci_config = @import("../pci/config.zig");
const PciConfigSpace = pci_config.PciConfigSpace;
const Bar = @import("../pci/bar.zig").Bar;
const BarAllocator = @import("../pci/bar.zig").BarAllocator;
const Block = @import("block.zig").Block;
const Vm = @import("../../root.zig").Vm;
pub const c = @cImport({
    @cInclude("linux/virtio_pci.h");
});
const BarMmio = @import("../pci/root.zig").BarMmio;

const log = std.log.scoped(.virtio_pci);

const VENDOR_ID = 0x1AF4;

fn VirtioPci(comptime Device: type) type {
    return struct {
        config: PciConfigSpace,
        device: VirtioCore(Device),
        irq: u32,
        bars: [1]?Bar = @splat(null),

        const Self = @This();

        pub fn new(base: u64, device: VirtioCore(Device), vm: *Vm, irq: u32) !Self {
            _ = vm;
            _ = base;

            var config = PciConfigSpace.new_type0(
                VENDOR_ID,
                Device.PCI_CLASS,
                .Storage,
                Device.PCI_SUBCLASS,
            );

            // Generic cap
            const gen_cap = c.virtio_pci_cap{
                .cap_vndr = 0x09,
                .cap_next = 0,
                .cap_len = 16,
                .cfg_type = c.VIRTIO_PCI_CAP_COMMON_CFG,
                .bar = 0,
                .id = 0,
                .padding = @splat(0),
                .offset = 0,
                .length = @sizeOf(c.virtio_pci_common_cfg),
            };

            const isr_cap = c.virtio_pci_cap{
                .cap_vndr = 0x09,
                .cap_next = 0,
                .cap_len = 16,
                .cfg_type = c.VIRTIO_PCI_CAP_ISR_CFG,
                .bar = 0,
                .id = 0,
                .padding = @splat(0),
                .offset = gen_cap.offset + gen_cap.length,
                .length = 8,
            };

            const notify_cap = c.virtio_pci_cap{
                .cap_vndr = 0x09,
                .cap_next = 0,
                .cap_len = 16,
                .cfg_type = c.VIRTIO_PCI_CAP_NOTIFY_CFG,
                .bar = 0,
                .id = 0,
                .padding = @splat(0),
                .offset = isr_cap.offset + isr_cap.length,
                .length = @sizeOf(c.virtio_pci_notify_cap),
            };

            try config.add_capability(std.mem.asBytes(&gen_cap));
            try config.add_capability(std.mem.asBytes(&isr_cap));
            try config.add_capability(std.mem.asBytes(&notify_cap));

            return .{
                .config = config,
                .device = device,
                .irq = irq,
            };
        }

        fn mmio_read(self: *Self, offset: usize, data: []u8, io: std.Io) !void {
            _ = self;
            _ = io;
            log.debug("read from 0x{x}, data {x}\n", .{ offset, data });
            @panic("todo");
        }

        fn mmio_write(self: *Self, offset: usize, data: []const u8, io: std.Io) !void {
            _ = self;
            _ = io;
            log.debug("write to 0x{x}, data {x}\n", .{ offset, data });
            @panic("todo");
        }
    };
}

pub const VirtioPciDevice = union(enum) {
    block: VirtioPci(Block),

    const Self = @This();

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
                .block = try VirtioPci(Block).new(
                    base_address,
                    VirtioCore(Block).new(try Block.new(path, io), alloc),
                    vm,
                    irq_num,
                ),
            },
        };
    }

    pub fn write_config(self: *Self, offset: u8, data: []const u8) !void {
        // Handle BAR writes
        if (offset >= 0x10 and offset <= 0x10 * 6) {
            std.debug.assert(offset % 4 == 0);
            std.debug.assert(data.len == 4);

            const bar = (offset - 0x10) / 4;

            switch (self.*) {
                inline else => |*device| {
                    if (bar < device.bars.len) {
                        if (device.bars[bar]) |b| {
                            if (std.mem.eql(u8, data[0..4], &.{ 0xff, 0xff, 0xff, 0xff })) {
                                try device.config.set_bar(@truncate(bar), @truncate(~(b.size - 1)));
                            } else {
                                try device.config.set_bar(@truncate(bar), std.mem.readInt(u32, data[0..4], .little));
                            }

                            return;
                        }
                    }
                },
            }
        }

        try self.get_config().write_slice(offset, data);
    }

    pub fn allocate_bars(self: *Self, alloc: *BarAllocator) !void {
        return switch (self.*) {
            inline else => |*device| {
                for (&device.bars, 0..) |*bar, i| {
                    std.debug.assert(bar.* == null);

                    bar.* = try alloc.allocate(4096);
                    try device.config.set_bar(@truncate(i), bar.*.?.value());
                }
            },
        };
    }

    fn mmio_read(context: *anyopaque, offset: usize, data: []u8, io: std.Io) !void {
        const self: *Self = @ptrCast(@alignCast(context));

        return switch (self.*) {
            inline else => |*device| {
                try device.mmio_read(offset, data, io);
            },
        };
    }

    fn mmio_write(context: *anyopaque, offset: usize, data: []const u8, io: std.Io) !void {
        const self: *Self = @ptrCast(@alignCast(context));

        return switch (self.*) {
            inline else => |*device| {
                try device.mmio_write(offset, data, io);
            },
        };
    }

    pub fn bar_mmio(self: *Self) ?BarMmio {
        return switch (self.*) {
            inline else => |*device| {
                if (device.bars[0]) |bar| {
                    return .{
                        .base = bar.base,
                        .size = bar.size,
                        .dev = .{
                            .context = self,
                            .read_fn = mmio_read,
                            .write_fn = mmio_write,
                        },
                    };
                }

                return null;
            },
        };
    }

    pub fn deinit(self: *Self, io: std.Io) void {
        _ = self;
        _ = io;
    }

    pub fn get_config(self: *Self) *PciConfigSpace {
        return switch (self.*) {
            inline else => |*device| &device.config,
        };
    }
};
