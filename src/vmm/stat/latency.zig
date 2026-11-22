// Latency statistics

const std = @import("std");
const linux = std.os.linux;
const Atomic = std.atomic.Value(usize);

fn get_thread_ns() usize {
    var ts: linux.timespec = undefined;

    const result = linux.clock_gettime(.THREAD_CPUTIME_ID, &ts);
    std.debug.assert(result == 0);
    return @as(usize, @intCast(ts.sec)) * 1000000000 + @as(usize, @intCast(ts.nsec));
}

pub const LatencyStat = struct {
    max: Atomic = .init(0),
    min: Atomic = .init(std.math.maxInt(usize)),
    sum: Atomic = .init(0),
    count: Atomic = .init(0),

    const Self = @This();

    fn update(self: *Self, elapsed: usize) void {
        _ = self.max.fetchMax(elapsed, .monotonic);
        _ = self.min.fetchMin(elapsed, .monotonic);
        _ = self.sum.fetchAdd(elapsed, .monotonic);
        _ = self.count.fetchAdd(1, .monotonic);
    }

    pub const Tracker = struct {
        start: usize,
        stat: *Self,

        pub fn deinit(self: *Tracker) void {
            const end = get_thread_ns();

            self.stat.update(end - self.start);
        }
    };

    pub fn track(self: *Self) Tracker {
        return .{ .start = get_thread_ns(), .stat = self };
    }
};
