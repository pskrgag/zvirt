//! Various helpers

pub const Lazy = @import("lazy.zig");
pub const Epoll = @import("epoll.zig");
pub const EventFd = @import("eventfd.zig");

test {
    _ = @import("lazy.zig");
    _ = @import("epoll.zig");
    _ = @import("eventfd.zig");
}
