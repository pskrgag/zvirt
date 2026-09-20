const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

const Sha256 = std.crypto.hash.sha2.Sha256;

const blkgetsize64 = linux.IOCTL.IOR(0x12, 114, u64);
const digest_prefix = "DISK-SHA256 ";

fn mount_devtmpfs() !void {
    const rc = linux.mount("devtmpfs", "/dev", "devtmpfs", 0, 0);
    if (linux.errno(rc) != .SUCCESS)
        return error.MountDevtmpfsFailed;
}

fn enable_raw_mode(fd: posix.fd_t) !void {
    var termios = try posix.tcgetattr(fd);

    termios.iflag.BRKINT = false;
    termios.iflag.ICRNL = false;
    termios.iflag.IGNBRK = false;
    termios.iflag.IGNCR = false;
    termios.iflag.INLCR = false;
    termios.iflag.INPCK = false;
    termios.iflag.ISTRIP = false;
    termios.iflag.IXON = false;

    termios.oflag.OPOST = false;

    termios.lflag.ECHO = false;
    termios.lflag.ECHONL = false;
    termios.lflag.ICANON = false;
    termios.lflag.IEXTEN = false;
    termios.lflag.ISIG = false;

    termios.cflag.CSIZE = .CS8;
    termios.cflag.PARENB = false;

    termios.cc[@intFromEnum(linux.V.MIN)] = 1;
    termios.cc[@intFromEnum(linux.V.TIME)] = 0;

    try posix.tcsetattr(fd, .NOW, termios);
}

fn disk_size(fd: posix.fd_t) !u64 {
    var size: u64 = undefined;
    const rc = linux.ioctl(fd, blkgetsize64, @intFromPtr(&size));

    if (linux.errno(rc) != .SUCCESS)
        return error.GetDiskSizeFailed;

    return size;
}

fn hash_disk(fd: posix.fd_t, size: u64) ![Sha256.digest_length]u8 {
    var hasher = Sha256.init(.{});
    var buffer: [64 * 1024]u8 = undefined;
    var remaining = size;

    while (remaining > 0) {
        const requested: usize = @intCast(@min(remaining, buffer.len));
        const bytes_read = try posix.read(fd, buffer[0..requested]);

        if (bytes_read == 0)
            return error.UnexpectedEndOfDisk;

        hasher.update(buffer[0..bytes_read]);
        remaining -= bytes_read;
    }

    var digest: [Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

fn write_digest(file: std.Io.File, io: std.Io, digest: [Sha256.digest_length]u8) !void {
    const hex = std.fmt.bytesToHex(digest, .lower);
    var message: [digest_prefix.len + hex.len + 1]u8 = undefined;

    @memcpy(message[0..digest_prefix.len], digest_prefix);
    @memcpy(message[digest_prefix.len..][0..hex.len], &hex);
    message[message.len - 1] = '\n';

    try file.writeStreamingAll(io, &message);
}

fn drain(fd: posix.fd_t) !void {
    const rc = linux.tcdrain(fd);
    if (linux.errno(rc) != .SUCCESS)
        return error.DrainFailed;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    try mount_devtmpfs();

    const output_fd = try posix.openat(
        posix.AT.FDCWD,
        "/dev/ttyS1",
        .{ .ACCMODE = .RDWR, .CLOEXEC = true },
        0,
    );
    const output: std.Io.File = .{
        .handle = output_fd,
        .flags = .{ .nonblocking = false },
    };
    defer output.close(io);

    try enable_raw_mode(output_fd);

    const disk_fd = try posix.openat(
        posix.AT.FDCWD,
        "/dev/vda",
        .{ .ACCMODE = .RDONLY, .CLOEXEC = true },
        0,
    );
    defer _ = linux.close(disk_fd);

    const digest = try hash_disk(disk_fd, try disk_size(disk_fd));
    try write_digest(output, io, digest);
    try drain(output_fd);

    try std.Io.File.stdout().writeStreamingAll(io, "\nEND\n");

    // Writes to console are async. So it's not possible to guarantee that after exit(), these bytes
    // would reach zvirt buffer.
    while (true) {}
}
