//! Device drivers

const std = @import("std");

pub const uart_16550 = @import("uart_16550.zig");
pub const cmos = @import("cmos.zig");
pub const mc146818rtc = @import("mc146818rtc.zig");
pub const VirtioMmioDevice = @import("virtio/mmio.zig").VirtioMmioDevice;

pub const MmioDevice = struct {
    context: *anyopaque,
    read_fn: *const fn (*anyopaque, usize, []u8, std.Io) anyerror!void,
    write_fn: *const fn (*anyopaque, usize, []const u8, std.Io) anyerror!void,
};
