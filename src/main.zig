const std = @import("std");
const cli = @import("cli");
const zvirt = @import("zvirt");
const Vm = zvirt.vmm.Vm;

const DEFAULT_MEMORY_SIZE = 1 << 30;

var config = struct {
    kernel: []const u8 = "",
    memory: []const u8 = "",
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
    const kernel = std.ArrayList(u8).fromOwnedSlice(kernel_bytes);

    var vm = try Vm.new(.{ .memory = memory_size }, io, allocator);
    defer vm.deinit();

    try vm.load_binary(kernel);
    try vm.run();
}
