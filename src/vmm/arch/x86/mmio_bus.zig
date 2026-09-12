//! x86 MMIO bus

const std = @import("std");
const device = @import("../../device/root.zig");
const Io = std.Io;
const IoResult = @import("kvm").IoResult;
const VirtioMmioDevice = @import("../../device/root.zig").VirtioMmioDevice;
const log = std.log.scoped(.mmio_bus);
const Vm = @import("../../root.zig").Vm;

pub const MAX_DEVICES = 10;
const Self = @This();

buffer: [MAX_DEVICES]VirtioMmioDevice,
virtio_devs: std.ArrayList(VirtioMmioDevice),

pub fn handle_event(
    self: *Self,
    id: u29,
    fd: std.posix.fd_t,
    io: std.Io,
) !void {
    try self.virtio_devs.items[id].handle_event(fd, io);
}

pub fn handle_mmio(self: *Self, mmio_request: anytype, io: std.Io) !?IoResult {
    // log.debug("access: {any}", .{mmio_request});
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
                    // log.debug("virtio offset 0x{x}", .{offset});

                    if (!mmio_request.write) {
                        const res = try dev.handle_read(@truncate(offset), io);

                        return IoResult{ .Mmio = .{ .data = res } };
                    } else {
                        try dev.handle_write(@truncate(offset), @truncate(mmio_request.data), io);
                        return null;
                    }
                }
            }

            log.err("unhandled MMIO address 0x{x}", .{mmio_request.pa});
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

    self.virtio_devs = std.ArrayList(VirtioMmioDevice).initBuffer(&self.buffer);
    return self;
}

pub fn register_device(self: *Self, vm: *Vm, dev: VirtioMmioDevice) !void {
    const id = self.virtio_devs.items.len;

    try dev.register_events(vm, @truncate(id));

    self.virtio_devs.appendAssumeCapacity(dev);
}
