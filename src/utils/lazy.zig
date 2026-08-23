const std = @import("std");
const Value = std.atomic.Value;
const futex = std.os.linux.futex;

const PENDING = 0;
const EVALUATING = 1;
const DONE = 2;

pub fn Lazy(T: type) type {
    return struct {
        f: *const fn () anyerror!T,
        state: Value(u32),
        result: anyerror!T,

        const Self = @This();

        pub fn get(self: *Self) !*T {
            while (true) {
                const res = self.state.cmpxchgStrong(PENDING, EVALUATING, .acquire, .acquire);

                if (res) |old| {
                    switch (old) {
                        EVALUATING => {
                            _ = futex(
                                &self.state,
                                .{ .private = true, .cmd = .WAIT },
                                EVALUATING,
                                .{ .timeout = null },
                                null,
                                0,
                            );
                        },
                        DONE => {
                            return &(try self.result);
                        },
                        else => @panic("Invalid state"),
                    }
                } else {
                    self.result = self.f();

                    self.state.store(DONE, .release);

                    _ = futex(
                        &self.state,
                        .{ .private = true, .cmd = .WAKE },
                        1,
                        .{ .timeout = null },
                        null,
                        0,
                    );
                }
            }
        }
    };
}

pub fn lazy(T: type, f: *const fn () anyerror!T) Lazy(T) {
    return .{ .f = f, .state = Value(u32).init(PENDING), .result = undefined };
}

test "successful evaluation is cached" {
    const Fixture = struct {
        var calls = Value(u32).init(0);

        fn create() !i32 {
            _ = calls.fetchAdd(1, .monotonic);
            return 0xdead;
        }
    };

    Fixture.calls.store(0, .monotonic);
    var lz = lazy(i32, Fixture.create);

    const first = try lz.get();
    const second = try lz.get();
    const third = try lz.get();

    try std.testing.expectEqual(@as(i32, 0xdead), first.*);
    try std.testing.expectEqual(first, second);
    try std.testing.expectEqual(first, third);
    try std.testing.expectEqual(@as(u32, 1), Fixture.calls.load(.monotonic));
}

test "failed evaluation is cached" {
    const Fixture = struct {
        var calls = Value(u32).init(0);

        fn create() !i32 {
            _ = calls.fetchAdd(1, .monotonic);
            return error.ExpectedFailure;
        }
    };

    Fixture.calls.store(0, .monotonic);
    var lz = lazy(i32, Fixture.create);

    try std.testing.expectError(error.ExpectedFailure, lz.get());
    try std.testing.expectError(error.ExpectedFailure, lz.get());
    try std.testing.expectEqual(@as(u32, 1), Fixture.calls.load(.monotonic));
}

test "concurrent callers evaluate once" {
    const thread_count = 8;
    const Fixture = struct {
        var calls = Value(u32).init(0);
        var ready = Value(u32).init(0);
        var start = Value(bool).init(false);

        fn create() !i32 {
            _ = calls.fetchAdd(1, .monotonic);
            return 42;
        }

        fn worker(lz: *Lazy(i32), result: *anyerror!*i32) void {
            _ = ready.fetchAdd(1, .release);
            while (!start.load(.acquire)) std.atomic.spinLoopHint();
            result.* = lz.get();
        }
    };

    Fixture.calls.store(0, .monotonic);
    Fixture.ready.store(0, .monotonic);
    Fixture.start.store(false, .monotonic);

    var lz = lazy(i32, Fixture.create);
    var results: [thread_count]anyerror!*i32 = undefined;
    var threads: [thread_count]std.Thread = undefined;

    for (&threads, &results) |*thread, *result| {
        thread.* = try std.Thread.spawn(.{}, Fixture.worker, .{ &lz, result });
    }

    while (Fixture.ready.load(.acquire) != thread_count) std.atomic.spinLoopHint();
    Fixture.start.store(true, .release);

    for (&threads) |thread| thread.join();
    for (results) |result| {
        try std.testing.expectEqual(@as(i32, 42), (try result).*);
    }
    try std.testing.expectEqual(@as(u32, 1), Fixture.calls.load(.monotonic));
}
