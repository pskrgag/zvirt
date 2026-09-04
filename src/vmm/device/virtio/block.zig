//! Virtio block device

const std = @import("std");
const queue = @import("queue.zig");

pub const c = @cImport({
    @cInclude("linux/virtio_blk.h");
});

const VIRTIO_BLK_F_RO: u32 = 1 << 5;

const VIRTIO_BLK_S_OK: u8 = 0;
const VIRTIO_BLK_S_IOERR: u8 = 1;
const VIRTIO_BLK_S_UNSUPP: u8 = 2;

const BlockRequestKind = enum(u32) {
    Read = 0,
    Write = 1,
    Flush = 5,
};

const BlockRequest = extern struct {
    kind: BlockRequestKind,
    reserved: u32,
    sector: u64,
};

pub const Block = struct {
    config: c.virtio_blk_config,
    file: std.Io.File,

    pub const TYPE = 0x2;

    const Self = @This();

    pub fn new(path: []const u8, io: std.Io) !Self {
        var config = std.mem.zeroes(c.virtio_blk_config);
        var file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });

        const stat = try file.stat(io);
        config.capacity = stat.size / 512;

        return .{
            .config = config,
            .file = file,
        };
    }

    pub fn deinit(self: *Self, io: std.Io) void {
        self.file.close(io);
    }

    pub fn features() u32 {
        return VIRTIO_BLK_F_RO;
    }

    pub fn proccess_requests(self: *Self, reqs: []queue.RequestChain, io: std.Io) !void {
        for (reqs) |*req| {
            req.len = try self.proccess_request(req, io);
        }
    }

    fn proccess_request(self: *Self, req: *const queue.RequestChain, io: std.Io) !u32 {
        const requests = req.get_requests();

        if (requests.len != 3) {
            std.debug.print("Unusual layout for blk request\n", .{});
            @panic("todo");
        }

        if (requests[0].len() != @sizeOf(BlockRequest)) {
            std.debug.print("\n", .{});
            @panic("todo");
        }

        const blkreq: *align(1) const BlockRequest = @ptrCast(requests[0].as_ro().ptr);
        const status: []u8 = requests[2].as_rw() orelse {
            std.debug.print("not writable third descr\n", .{});
            return error.InvalidFormat;
        };

        const to_write = requests[1].as_rw() orelse {
            std.debug.print("not writable second descr\n", .{});
            status[0] = VIRTIO_BLK_S_IOERR;
            return error.InvalidFormat;
        };

        const len = self.file.readPositionalAll(io, to_write, blkreq.sector * 512) catch {
            status[0] = VIRTIO_BLK_S_IOERR;
            return 0;
        };

        status[0] = VIRTIO_BLK_S_OK;

        // Account for status write
        return @truncate(len + 1);
    }

    pub fn read_config(self: *Self, offset: u32) u32 {
        return std.mem.readInt(u32, std.mem.asBytes(&self.config)[offset..][0..4], .little);
    }
};
