//! Ioctl wrapper

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

pub fn ioctl(fd: posix.fd_t, request: u32, arg: usize) !usize {
    const rc = linux.ioctl(fd, request, arg);

    switch (linux.errno(rc)) {
        .SUCCESS => {
            return rc;
        },
        .INTR => {
            return error.Interrupted;
        },
        .AGAIN => {
            return error.Retry;
        },
        else => {
            return error.IoctlFailed;
        },
    }
}
