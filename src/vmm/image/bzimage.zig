//! bzImage parser

pub const c = @cImport({
    @cInclude("asm/bootparam.h");
});

const VmConfig = @import("../root.zig").VmConfig;
const builtin = @import("builtin");
const arch = switch (builtin.cpu.arch) {
    .x86, .x86_64 => @import("../arch/x86/root.zig"),
    else => @compileError("unsupported architecture"),
};
const std = @import("std");
const Image = @import("root.zig").Image;
const GuestMemory = @import("../memory.zig").GuestMemory;

pub const SETUP_HEADER_OFFSET = 0x1F1;
pub const SETUP_HEADER_SIZE = 0x7B;

pub const SetupHeader = c.setup_header;
pub const BootParams = c.boot_params;

comptime {
    std.debug.assert(@bitSizeOf(SetupHeader) == SETUP_HEADER_SIZE * 8);
    std.debug.assert(@bitOffsetOf(SetupHeader, "boot_flag") / 8 == 0x0D);
    std.debug.assert(@bitOffsetOf(SetupHeader, "header") / 8 == 0x11);
    std.debug.assert(@bitOffsetOf(SetupHeader, "version") / 8 == 0x15);
    std.debug.assert(@bitOffsetOf(SetupHeader, "kernel_info_offset") / 8 == 0x77);
}

const BOOTFLAG = 0xAA55;
const MAGIC = 0x53726448;
const SUPPORTED_VERSION = 0x20f;

const MINIMAL_SIZE = SETUP_HEADER_OFFSET + @bitSizeOf(SetupHeader) / 8;
const DEFAULT_CMD_LINE: [*:0]const u8 = "console=ttyS0 earlycon=uart,io,0x3f8 nokaslr pci=off";

fn fill_e820(params: *BootParams, config: *const VmConfig) void {
    const layout = arch.layout.memory_layout(config);

    for (layout, 0..) |entry, i| {
        params.e820_table[i].addr = entry.start;
        params.e820_table[i].size = entry.length;
        params.e820_table[i].type = @intFromEnum(entry.kind);
    }

    params.e820_entries = @intCast(layout.len);
}

pub fn parse(data: []const u8, memory: *GuestMemory, config: *const VmConfig) !Image {
    var boot_params = BootParams{};

    if (data.len < MINIMAL_SIZE)
        return error.ImageTooSmall;

    const header: *align(1) const SetupHeader = @ptrCast(data.ptr + SETUP_HEADER_OFFSET);

    if (header.header != MAGIC)
        return error.InvalidHeader;

    if (@as(usize, (header.jump >> 8) + 0x11) < @bitSizeOf(SetupHeader) / 8)
        return error.InvalidHeaderSize;

    if (header.version != SUPPORTED_VERSION)
        return error.InvalidVersion;

    if (header.boot_flag != BOOTFLAG)
        return error.InvalidBootflag;

    // For now support only bzImage
    if (header.loadflags & (1 << 0) == 0)
        return error.InvalidLoadFlags;

    // For now support only legacy variant
    if (header.xloadflags & (1 << 0) == 0)
        return error.InvalidxLoadFlags;

    // For now keep 1Gib for simplicity
    if (header.init_size > 1 << 30)
        return error.InvalidInitSize;

    fill_e820(&boot_params, config);

    std.debug.assert(arch.layout.BOOT_CMDLINE_ADDR >> 32 == 0);

    const sects = if (header.setup_sects == 0) 4 else header.setup_sects;
    const kernel_offset = @as(usize, (sects + 1)) * 512;

    @memcpy(std.mem.asBytes(&boot_params.hdr), std.mem.asBytes(header));
    boot_params.hdr.cmd_line_ptr = arch.layout.BOOT_CMDLINE_ADDR;

    const zig_slice = std.mem.span(
        @as([*:0]const u8, @ptrCast(DEFAULT_CMD_LINE)),
    );

    try memory.write(arch.layout.BOOT_CMDLINE_ADDR, zig_slice);
    try memory.write(arch.layout.BOOT_PARAM_ADDR, std.mem.asBytes(&boot_params));
    try memory.write(0x100000, data[kernel_offset..]);

    return .{
        .ep = 0x100000 + 0x200,
        .load_address = 0x100000,
    };
}

test "test Linux kernel" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const binary_bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "test_bins/bzImage",
        allocator,
        .unlimited,
    );
    defer allocator.free(binary_bytes);
    var mem = try GuestMemory.new(allocator);
    defer mem.deinit(allocator);

    const ram = try std.posix.mmap(
        null,
        1 << 30,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    );

    try mem.add(0x0, ram[0 .. 1 << 30], allocator);
    _ = try parse(binary_bytes, &mem, &VmConfig{ .ram_size = 2 << 30, .binary = "" });
}
