//! Line-oriented CI runner for Zig 0.16. Local runs retain Zig's default runner.
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

pub const std_options: std.Options = .{ .logFn = log };
var logged_errors = std.atomic.Value(usize).init(0);

pub fn main(init: std.process.Init.Minimal) void {
    @disableInstrumentation();
    var passed: usize = 0;
    var skipped: usize = 0;
    var failed: usize = 0;
    var leaks: usize = 0;

    for (builtin.test_functions, 0..) |test_fn, i| {
        std.debug.print("START {d}/{d} {s}\n", .{ i + 1, builtin.test_functions.len, test_fn.name });
        testing.allocator_instance = .{};
        testing.io_instance = .init(testing.allocator, .{
            .argv0 = .init(init.args),
            .environ = init.environ,
        });
        testing.environ = init.environ;
        testing.log_level = .warn;

        const errors_before = logged_errors.load(.monotonic);
        var result: enum { pass, skip, fail } = .pass;
        test_fn.func() catch |err| {
            if (err == error.SkipZigTest) {
                result = .skip;
            } else {
                result = .fail;
                std.debug.print("ERROR {s}: {t}\n", .{ test_fn.name, err });
                if (@errorReturnTrace()) |trace| {
                    std.debug.dumpErrorReturnTrace(trace);
                }
            }
        };

        testing.io_instance.deinit();
        if (testing.allocator_instance.deinit() == .leak) {
            leaks += 1;
            result = .fail;
        }
        if (logged_errors.load(.monotonic) != errors_before) {
            result = .fail;
        }

        switch (result) {
            .pass => passed += 1,
            .skip => skipped += 1,
            .fail => failed += 1,
        }
        std.debug.print("{s} {d}/{d} {s}\n", .{
            switch (result) {
                .pass => "PASS",
                .skip => "SKIP",
                .fail => "FAIL",
            },
            i + 1,
            builtin.test_functions.len,
            test_fn.name,
        });
    }

    std.debug.print("SUMMARY: {d} passed, {d} skipped, {d} failed, {d} leaked\n", .{ passed, skipped, failed, leaks });
    if (failed != 0 or logged_errors.load(.monotonic) != 0) {
        std.process.exit(1);
    }
}

pub fn log(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
    @disableInstrumentation();
    if (level == .err) {
        _ = logged_errors.fetchAdd(1, .monotonic);
    }
    if (@intFromEnum(level) <= @intFromEnum(testing.log_level)) {
        std.debug.print("[" ++ @tagName(scope) ++ "] (" ++ @tagName(level) ++ "): " ++ format ++ "\n", args);
    }
}
