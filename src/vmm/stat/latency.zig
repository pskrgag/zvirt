// Latency statistics

const std = @import("std");
const linux = std.os.linux;
const Atomic = std.atomic.Value(usize);
const Mutex = std.Io.Mutex;

fn get_thread_ns() usize {
    var ts: linux.timespec = undefined;

    const result = linux.clock_gettime(.THREAD_CPUTIME_ID, &ts);
    std.debug.assert(result == 0);
    return @as(usize, @intCast(ts.sec)) * 1000000000 + @as(usize, @intCast(ts.nsec));
}

pub const LatencyStat = struct {
    latency: Latency = .{},
    mutex: Mutex = .init,

    pub const Latency = struct {
        max: usize = 0,
        min: usize = std.math.maxInt(usize),
        sum: usize = 0,
        count: usize = 0,
    };

    const Self = @This();

    fn update(self: *Self, elapsed: usize, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        self.latency.max = @max(elapsed, self.latency.max);
        self.latency.min = @min(elapsed, self.latency.min);
        self.latency.sum += elapsed;
        self.latency.count += 1;
    }

    pub const Tracker = struct {
        start: usize,
        stat: *Self,

        pub fn deinit(self: *Tracker, io: std.Io) void {
            const end = get_thread_ns();

            self.stat.update(end - self.start, io);
        }
    };

    pub fn read(self: *Self, io: std.Io) Latency {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        return self.latency;
    }

    pub fn track(self: *Self) Tracker {
        return .{ .start = get_thread_ns(), .stat = self };
    }
};
