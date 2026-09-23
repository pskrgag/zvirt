//! Various helpers

pub const Lazy = @import("lazy.zig");
pub const Epoll = @import("epoll.zig");
pub const EventFd = @import("eventfd.zig");
pub const IdAlloc = @import("idalloc.zig");
pub const Tap = @import("tap.zig").Tap;

test {
    _ = @import("lazy.zig");
    _ = @import("epoll.zig");
    _ = @import("eventfd.zig");
    _ = @import("idalloc.zig");
    // _ = @import("tap.zig");
}
