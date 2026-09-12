//! PCI virtio device

const std = @import("std");
const virtio = @import("root.zig");
const VirtioCore = virtio.VirtioCore;
const VirtioDeviceInit = virtio.VirtioDeviceInit;
const pci_config = @import("../pci/config.zig");
const PciConfigSpace = pci_config.PciConfigSpace;
const Block = @import("block.zig").Block;
const Vm = @import("../../root.zig").Vm;
pub const c = @cImport({
    @cInclude("linux/virtio_pci.h");
});

const VENDOR_ID = 0x1AF4;

fn VirtioPci(comptime Device: type) type {
    return struct {
        config: PciConfigSpace,
        device: VirtioCore(Device),
        irq: u32,

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

            try config.add_capability(std.mem.asBytes(&gen_cap));

            return .{
                .config = config,
                .device = device,
                .irq = irq,
            };
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
