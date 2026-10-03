const std = @import("std");

pub const EventSource = struct {
    fd: std.posix.fd_t,
    edge: bool,
};

pub fn EventSources(comptime capacity: usize) type {
    return struct {
        entries: [capacity]EventSource = undefined,
        count: usize = 0,

        pub fn slice(self: *const @This()) []const EventSource {
            return self.entries[0..self.count];
        }
    };
}
