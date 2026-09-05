const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

const write_seed = 0x5a17_c3e2_91bd_704f;
const write_size = 256 << 10;

fn mount_devtmpfs() !void {
    const rc = linux.mount("devtmpfs", "/dev", "devtmpfs", 0, 0);
    if (linux.errno(rc) != .SUCCESS)
        return error.MountDevtmpfsFailed;
}

fn write_pattern(file: std.Io.File, io: std.Io, seed: u64, size: u64) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    var buffer: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;

    while (offset < size) {
        const length: usize = @intCast(@min(size - offset, buffer.len));
        const bytes = buffer[0..length];

        random.bytes(bytes);
        try file.writePositionalAll(io, bytes, offset);
        offset += bytes.len;
    }

    try file.sync(io);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    try mount_devtmpfs();

    const disk_fd = try posix.openat(
        posix.AT.FDCWD,
        "/dev/vda",
        .{ .ACCMODE = .RDWR, .CLOEXEC = true },
        0,
    );
    const disk: std.Io.File = .{
        .handle = disk_fd,
        .flags = .{ .nonblocking = false },
    };
    defer disk.close(io);

    try write_pattern(disk, io, write_seed, write_size);

    try std.Io.File.stdout().writeStreamingAll(io, "\nEND\n");
}
