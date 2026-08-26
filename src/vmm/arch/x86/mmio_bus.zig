//! x86 MMIO bus

const std = @import("std");
const device = @import("../../device/root.zig");
const Io = std.Io;
const IoResult = @import("kvm").IoResult;

const Self = @This();

pub fn handle_mmio(self: *Self, mmio_request: anytype, io: std.Io) !?IoResult {
    _ = self;
    _ = io;

    // std.debug.print("trying {}\n", .{mmio_request.pa});
    switch (mmio_request.pa) {
        0xa0000...0xbffff,
        0xc0000...0xfffff,
        => return IoResult{ .Mmio = .{ .data = 0xffffffffffffffff } },
        else => @panic("todo"),
    }
}
