//! Character device

const std = @import("std");
const File = std.Io.File;
const Vm = @import("../root.zig").Vm;
const posix = std.posix;

const log = std.log.scoped(.chardev);

// TODO: do we even need support for other type of streams? I doubt it

fn setup_terminal(fd: posix.fd_t) !posix.termios {
    const original = try posix.tcgetattr(fd);
    var raw = original;

    // Deliver input without waiting for a newline.
    raw.lflag.ICANON = false;

    // Do not echo typed characters.
    raw.lflag.ECHO = false;

    // Keep Ctrl-C, Ctrl-Z, etc. working as signals.
    raw.lflag.ISIG = false;

    // A read may return as soon as one byte is available.
    raw.cc[@intFromEnum(posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(posix.V.TIME)] = 0;

    try posix.tcsetattr(fd, .NOW, raw);

    return original;
}

pub const CharDev = struct {
    in: ?File,
    out: File,
    vm: *Vm,
    storage: []u8,
    rx_queue: std.Deque(u8),
    orig_tcattr: ?posix.termios = null,
    pending_escape: bool = false,

    const Self = @This();

    pub fn new(out: File, in: ?File, vm: *Vm, rx_queue_size: usize, term: bool, alloc: std.mem.Allocator) !Self {
        const storage = try alloc.alloc(u8, rx_queue_size);
        errdefer alloc.free(storage);

        const orig_tcattr = if (term)
            try setup_terminal(out.handle)
        else
            null;
        errdefer {
            if (orig_tcattr) |tcattr| {
                posix.tcsetattr(out.handle, .NOW, tcattr) catch @panic("failed to restore term");
            }
        }

        return .{
            .in = in,
            .out = out,
            .vm = vm,
            .storage = storage,
            .rx_queue = std.Deque(u8).initBuffer(storage),
            .orig_tcattr = orig_tcattr,
        };
    }

    pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
        if (self.orig_tcattr) |tcattr| {
            posix.tcsetattr(self.out.handle, .NOW, tcattr) catch @panic("failed to restore term");
        }

        alloc.free(self.storage);
    }

    pub fn pop_byte(self: *Self) ?u8 {
        return self.rx_queue.popFront();
    }

    pub fn rx_queue_is_empty(self: *const Self) bool {
        return self.rx_queue.len == 0;
    }

    pub fn is_terminal(self: *const Self) bool {
        return self.orig_tcattr != null;
    }

    pub fn handle_event(self: *Self, io: std.Io) !void {
        while (true) {
            var buffer: [1024]u8 = undefined;
            var buffers: [1][]u8 = .{&buffer};

            // Events are registered only when an input stream is attached.
            const read = try self.in.?.readStreaming(io, &buffers);
            for (buffer[0..read]) |byte| {
                if (self.is_terminal()) {
                    if (byte == 0x01) {
                        self.pending_escape = true;
                        continue;
                    }

                    if (self.pending_escape) {
                        switch (byte) {
                            'x' => {
                                log.warn("Stopping VM by console request", .{});
                                self.vm.stop() catch @panic("VM must be running");

                                // Break the loop, since vm must be stopped anyway.
                                self.pending_escape = false;
                                break;
                            },
                            's' => {
                                log.warn("Snapshotting VM", .{});
                            },
                            else => {},
                        }
                    }

                    self.pending_escape = false;
                }

                // Data loss
                self.rx_queue.pushBackBounded(byte) catch log.err("rx buffer overflow", .{});
            }

            if (read < buffer.len) {
                break;
            }
        }
    }

    pub fn write(self: *Self, bytes: []const u8, io: std.Io) !void {
        try self.out.writeStreamingAll(io, bytes);
    }
};
