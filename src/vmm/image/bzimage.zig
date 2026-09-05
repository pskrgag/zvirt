//! bzImage parser

pub const c = @cImport({
    @cInclude("asm/bootparam.h");
});

const VmConfig = @import("../root.zig").VmConfig;
const builtin = @import("builtin");
const arch = switch (builtin.cpu.arch) {
    .x86, .x86_64 => @import("../arch/x86/vm.zig"),
    else => @compileError("unsupported architecture"),
};
const std = @import("std");
const Image = @import("root.zig").Image;
const GuestMemory = @import("../memory.zig").GuestMemory;
const test_utils = @import("test_utils");
const mmap = @import("test_utils").mmap;

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
const DEFAULT_CMD_LINE: []const u8 = "console=ttyS0 earlycon=uart,io,0x3f8 nokaslr pci=off panic=-1 reboot=t";

fn fill_e820(params: *BootParams, config: *const VmConfig) void {
    const layout = arch.layout.memory_layout(config);

    for (layout, 0..) |entry, i| {
        params.e820_table[i].addr = entry.start;
        params.e820_table[i].size = entry.length;
        params.e820_table[i].type = @intFromEnum(entry.kind);
    }

    params.e820_entries = @intCast(layout.len);
}

pub fn parse(
    data: []const u8,
    memory: *GuestMemory,
    config: *const VmConfig,
) !Image {
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

    // We want to load initramfs above 4G
    if (header.xloadflags & (1 << 1) == 0)
        return error.InvalidxLoadFlags;

    // For now keep 1Gib for simplicity
    if (header.init_size > 1 << 30)
        return error.InvalidInitSize;

    if (config.binary.len > config.ram_size) {
        return error.InvalidImageSize;
    }

    @memcpy(std.mem.asBytes(&boot_params.hdr), std.mem.asBytes(header));

    if (config.initramfs) |fs| {
        // Now we know that both things should fit. We load image at the beginning of high RAM. And
        // initrd at the end of the high ram to prevent accidental overwrite during decompress
        const high_ram_end = arch.layout.HIGH_RAM_BEGIN + config.ram_size;
        const initrd_begin = std.mem.alignBackward(
            u64,
            high_ram_end - fs.len,
            4096,
        );

        if (initrd_begin + fs.len > arch.layout.HIGH_RAM_BEGIN + config.ram_size) {
            return error.InvalidImageSize;
        }

        try memory.write(initrd_begin, fs);

        boot_params.hdr.ramdisk_image = @truncate(initrd_begin);
        boot_params.ext_ramdisk_image = @truncate(initrd_begin >> 32);

        boot_params.hdr.ramdisk_size = @truncate(fs.len);
        boot_params.ext_ramdisk_size = @truncate(fs.len >> 32);
    }

    fill_e820(&boot_params, config);

    std.debug.assert(arch.layout.BOOT_CMDLINE_ADDR >> 32 == 0);

    const sects = if (header.setup_sects == 0) 4 else header.setup_sects;
    const kernel_offset = @as(usize, (sects + 1)) * 512;

    boot_params.hdr.cmd_line_ptr = arch.layout.BOOT_CMDLINE_ADDR;

    // NOTE: linux needs type_of_loader to be set for initramfs. Not sure why...
    boot_params.hdr.type_of_loader = 0xff;

    try memory.write(arch.layout.BOOT_PARAM_ADDR, std.mem.asBytes(&boot_params));
    try memory.write(arch.layout.HIGH_RAM_BEGIN, data[kernel_offset..]);

    return .{
        .ep = arch.layout.HIGH_RAM_BEGIN + 0x200,
        .load_address = arch.layout.HIGH_RAM_BEGIN,
    };
}

test "test Linux kernel" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    try test_utils.mmap.init(allocator);
    defer test_utils.mmap.deinit() catch @panic("mmap leaked");

    const fds = try test_utils.FdLeakDetector.snapshot(io);
    defer fds.check_leak(io) catch @panic("fd leaked");

    const binary_bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "test_bins/bzImage",
        allocator,
        .unlimited,
    );
    defer allocator.free(binary_bytes);
    var mem = try GuestMemory.new(allocator);
    defer mem.deinit(allocator);

    const ram = try mmap.mmap(
        null,
        1 << 30,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    );
    errdefer mmap.munmap(ram);

    try mem.add(0x0, ram[0 .. 1 << 30], true, allocator);
    _ = try parse(binary_bytes, mem, &VmConfig{ .ram_size = 2 << 30, .binary = "" });
}
