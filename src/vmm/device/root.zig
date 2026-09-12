//! Device drivers

pub const uart_16550 = @import("uart_16550.zig");
pub const cmos = @import("cmos.zig");
pub const mc146818rtc = @import("mc146818rtc.zig");
pub const VirtioMmioDevice = @import("virtio/mmio.zig").VirtioMmioDevice;
