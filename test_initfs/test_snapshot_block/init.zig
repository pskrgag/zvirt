const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

const first_pattern = 0xa5;
const second_pattern = 0x5a;
const first_size = 256 << 10;
const second_size = 64 << 10;
const blkflsbuf = linux.IOCTL.IO(0x12, 97);

fn open(path: []const u8) !std.Io.File {
    return .{
        .handle = try posix.openat(posix.AT.FDCWD, path, .{
            .ACCMODE = .RDWR,
            .CLOEXEC = true,
        }, 0),
        .flags = .{ .nonblocking = false },
    };
}

fn message(console: std.Io.File, io: std.Io, bytes: []const u8) !void {
    try console.writeStreamingAll(io, bytes);
    if (linux.errno(linux.tcdrain(console.handle)) != .SUCCESS) {
        return error.DrainFailed;
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    if (linux.errno(linux.mount("devtmpfs", "/dev", "devtmpfs", 0, 0)) != .SUCCESS) {
        return error.MountDevtmpfsFailed;
    }

    const console = try open("/dev/ttyS1");
    defer console.close(io);

    var termios = try posix.tcgetattr(console.handle);
    termios.lflag.ICANON = false;
    termios.lflag.ECHO = false;
    termios.iflag.ICRNL = false;
    termios.oflag.OPOST = false;
    termios.cc[@intFromEnum(linux.V.MIN)] = 1;
    termios.cc[@intFromEnum(linux.V.TIME)] = 0;
    try posix.tcsetattr(console.handle, .NOW, termios);

    const disk = try open("/dev/vda");
    defer disk.close(io);

    // Deliberately do not fsync here: dirty guest pages must survive the snapshot.
    var buffer: [first_size]u8 = @splat(first_pattern);
    try disk.writePositionalAll(io, &buffer, 0);
    try message(console, io, "SNAPSHOT-READY\n");

    const command = "continue\n";
    var received: [command.len]u8 = undefined;
    var used: usize = 0;

    while (used < received.len) {
        const len = try posix.read(console.handle, received[used..]);
        if (len == 0) {
            return error.ConsoleClosed;
        }
        used += len;
    }
    if (!std.mem.eql(u8, command, &received)) {
        return error.InvalidContinueCommand;
    }

    // NOTE: BLKFLSBUF writes dirty block-device pages back and invalidates the cache,
    // so the following read must go through the restored virtqueue.
    try disk.sync(io);
    if (linux.errno(linux.ioctl(disk.handle, blkflsbuf, 0)) != .SUCCESS) {
        return error.FlushBlockCacheFailed;
    }

    @memset(&buffer, 0);

    const len = try disk.readPositionalAll(io, &buffer, 0);
    if (len != buffer.len or !std.mem.allEqual(u8, &buffer, first_pattern)) {
        return error.RestoredDiskContentMismatch;
    }

    const appended = buffer[0..second_size];
    @memset(appended, second_pattern);

    try disk.writePositionalAll(io, appended, first_size);
    try disk.sync(io);
    try message(console, io, "SNAPSHOT-PASS\n");

    while (true) {}
}
