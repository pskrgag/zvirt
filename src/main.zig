const std = @import("std");
const cli = @import("cli");
const zvirt = @import("zvirt");
const Vm = zvirt.vmm.Vm;

const log = std.log.scoped(.cli);

pub const std_options: std.Options = .{
    // Keep all levels compiled in so the CLI can enable debug logs in release builds.
    .log_level = .debug,
    .logFn = log_fn,
};

// Set before starting VM threads; read-only afterwards.
var runtime_log_level: std.log.Level = std.log.default_level;

fn log_fn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@intFromEnum(level) > @intFromEnum(runtime_log_level)) return;
    std.log.defaultLog(level, scope, format, args);
}

const DEFAULT_MEMORY_SIZE = 1 << 30;

var config = struct {
    kernel: []const u8 = "",
    memory: []const u8 = "",
    initramfs: []const u8 = "",
    block_device: []const u8 = "",
    cmdline: []const u8 = "",
    smp: []const u8 = "",
    enable_pci: bool = false,
    log_level: []const u8 = @tagName(std.log.Level.info),
    io: ?std.Io = null,
    allocator: ?std.mem.Allocator = null,
}{};

pub fn main(init: std.process.Init) !void {
    config.io = init.io;
    config.allocator = init.gpa;

    var runner = cli.AppRunner.init(&init);
    defer runner.deinit();

    const app: cli.App = .{
        .command = .{
            .name = "zvirt",
            .options = try runner.allocOptions(&.{ .{
                .short_alias = 'k',
                .long_name = "kernel",
                .help = "Kernel binary",
                .value_ref = runner.mkRef(&config.kernel),
                .required = true,
            }, .{
                .short_alias = 'm',
                .long_name = "memory",
                .help = "Memory size",
                .value_ref = runner.mkRef(&config.memory),
            }, .{
                .long_name = "initramfs",
                .help = "initramfs image",
                .value_ref = runner.mkRef(&config.initramfs),
            }, .{
                .long_name = "drive",
                .help = "fs image",
                .value_ref = runner.mkRef(&config.block_device),
            }, .{
                .long_name = "cmdline",
                .help = "command line",
                .value_ref = runner.mkRef(&config.cmdline),
            }, .{
                .long_name = "smp",
                .help = "number of vCPUs",
                .value_ref = runner.mkRef(&config.smp),
            }, .{
                .long_name = "enable-pci",
                .help = "Enable PCI support",
                .value_ref = runner.mkRef(&config.enable_pci),
            }, .{
                .long_name = "log-level",
                .help = "Global log level: err, warn, info, debug (default: " ++ @tagName(std.log.default_level) ++ ")",
                .value_ref = runner.mkRef(&config.log_level),
            } }),
            .target = .{ .action = .{ .exec = run } },
        },
    };

    try runner.run(&app);
}

fn parse_memory(memory: []const u8) !usize {
    const parseInt = std.fmt.parseInt;

    if (memory.len == 0)
        return DEFAULT_MEMORY_SIZE;

    return switch (memory[memory.len - 1]) {
        'G' => try parseInt(usize, memory[0 .. memory.len - 1], 0) << 30,
        'M' => try parseInt(usize, memory[0 .. memory.len - 1], 0) << 20,
        'K' => try parseInt(usize, memory[0 .. memory.len - 1], 0) << 10,
        else => try parseInt(usize, memory, 0),
    };
}

fn parse_block_device(data: []const u8) !struct { path: []const u8, async: bool } {
    var parts = std.mem.splitScalar(u8, data, ',');
    var path: []const u8 = "";
    var async: ?bool = null;

    std.debug.print("{s}\n", .{data});

    while (parts.next()) |part| {
        std.debug.print("{s}\n", .{part});
        const del = std.mem.find(u8, part, "=") orelse return error.InvalidFormat;
        const key = part[0..del];
        const value = part[del + 1 ..];

        if (std.mem.eql(u8, key, "file")) {
            if (path.len != 0)
                return error.AlreadySet;

            path = value;
        } else if (std.mem.eql(u8, key, "engine")) {
            if (async != null)
                return error.AlreadySet;

            if (std.mem.eql(u8, value, "async")) {
                async = true;
            } else if (std.mem.eql(u8, value, "sync")) {
                async = false;
            } else {
                return error.InvalidKey;
            }
        } else {
            return error.InvalidKey;
        }
    }

    return .{ .path = path, .async = async orelse true };
}

fn run() !void {
    runtime_log_level = std.meta.stringToEnum(std.log.Level, config.log_level) orelse {
        log.err("invalid log level '{s}'; expected err, warn, info, or debug", .{config.log_level});
        return error.InvalidArgument;
    };
    const io = config.io orelse return error.IoUnavailable;
    const allocator = config.allocator orelse return error.AllocatorUnavailable;
    const memory_size = try parse_memory(config.memory);
    const kernel_bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        config.kernel,
        allocator,
        .unlimited,
    );
    defer allocator.free(kernel_bytes);
    var initramfs: ?[]const u8 = null;

    if (config.initramfs.len != 0) {
        initramfs = try std.Io.Dir.cwd().readFileAlloc(
            io,
            config.initramfs,
            allocator,
            .unlimited,
        );
    }

    defer {
        if (initramfs) |data|
            allocator.free(data);
    }

    var smp: u8 = 1;

    if (config.smp.len != 0) {
        smp = try std.fmt.parseInt(u8, config.smp, 10);
        if (smp == 0) {
            log.err("SMP cannot be 0\n", .{});
            return error.InvalidArgument;
        }
    }

    const block = try parse_block_device(config.block_device);

    var vm = try Vm.new(.{
        .ram_size = memory_size,
        .binary = kernel_bytes,
        .initramfs = initramfs,
        .block_device = .{ .path = block.path, .async = block.async },
        .cmdline = config.cmdline,
        .smp = smp,
        .pci = config.enable_pci,
    }, io, allocator);
    defer vm.deinit(allocator, io);

    try vm.attach_console(.{
        .input = std.Io.File.stdin(),
        .output = std.Io.File.stdout(),
        .configure_terminal = true,
        .index = 0,
    });

    try vm.attach_console(.{
        .output = std.Io.File.stderr(),
        .configure_terminal = false,
        .index = 1,
    });
    try vm.run(allocator, io);
}
