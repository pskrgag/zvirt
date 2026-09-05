const std = @import("std");
const cli = @import("cli");
const zvirt = @import("zvirt");
const Vm = zvirt.vmm.Vm;

const DEFAULT_MEMORY_SIZE = 1 << 30;

var config = struct {
    kernel: []const u8 = "",
    memory: []const u8 = "",
    initramfs: []const u8 = "",
    block_device: []const u8 = "",
    cmdline: []const u8 = "",
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

fn run() !void {
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

    var vm = try Vm.new(.{
        .ram_size = memory_size,
        .binary = kernel_bytes,
        .initramfs = initramfs,
        .block_device = config.block_device,
        .cmdline = config.cmdline,
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
