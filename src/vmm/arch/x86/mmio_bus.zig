//! x86 MMIO bus

const std = @import("std");
const device = @import("../../device/root.zig");
const Io = std.Io;
const IoResult = @import("kvm").IoResult;
const VirtioDevice = @import("../../device/root.zig").VirtioDevice;

pub const MAX_DEVICES = 10;
const Self = @This();

buffer: [MAX_DEVICES]VirtioDevice,
virtio_devs: std.ArrayList(VirtioDevice),

pub fn handle_mmio(self: *Self, mmio_request: anytype, io: std.Io) !?IoResult {
    // std.debug.print("trying {any}\n", .{mmio_request});
    switch (mmio_request.pa) {
        0xa0000...0xbffff,
        0xc0000...0xfffff,
        => return IoResult{ .Mmio = .{ .data = 0xffffffffffffffff } },
        else => {
            const page_mask = ~(@as(u64, 4096) - 1);
            const base = mmio_request.pa & page_mask;
            const offset = mmio_request.pa - base;

            for (self.virtio_devs.items) |*dev| {
                if (dev.base() == base) {
                    std.debug.print("offset {x}\n", .{offset});

                    if (!mmio_request.write) {
                        const res = dev.handle_read(@truncate(offset));

                        return IoResult{ .Mmio = .{ .data = res } };
                    } else {
                        try dev.handle_write(@truncate(offset), @truncate(mmio_request.data), io);
                        return null;
                    }
                }
            }

            std.debug.print("0x{x}\n", .{mmio_request.pa});
            @panic("todo");
        },
    }
}

pub fn deinit(self: *Self, alloc: std.mem.Allocator, io: std.Io) void {
    for (self.virtio_devs.items) |*dev| {
        dev.deinit(io);
    }

    alloc.destroy(self);
}

pub fn new(alloc: std.mem.Allocator) !*Self {
    var self = try alloc.create(Self);

    self.virtio_devs = std.ArrayList(VirtioDevice).initBuffer(&self.buffer);
    return self;
}

pub fn register_device(self: *Self, dev: VirtioDevice) void {
    self.virtio_devs.appendAssumeCapacity(dev);
}
