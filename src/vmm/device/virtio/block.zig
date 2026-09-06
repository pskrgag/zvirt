//! Virtio block device

const std = @import("std");
const queue = @import("queue.zig");
const log = std.log.scoped(.virtio_blk);

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
    Flush = 4,
    GetId = 8,
};

const BlockRequest = extern struct {
    kind: u32,
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
        return 0;
    }

    pub fn proccess_requests(self: *Self, reqs: []queue.RequestChain, io: std.Io) !void {
        for (reqs) |*req| {
            req.len = try self.proccess_request(req, io);
        }
    }

    fn proccess_request(self: *Self, req: *const queue.RequestChain, io: std.Io) !u32 {
        const requests = req.get_requests();

        if (requests.len != 3) {
            log.err("unsupported descriptor layout: {} descriptors", .{requests.len});
            @panic("todo");
        }

        if (requests[0].len() != @sizeOf(BlockRequest)) {
            log.err("invalid request header length: expected {}, got {}", .{
                @sizeOf(BlockRequest),
                requests[0].len(),
            });
            @panic("todo");
        }

        const blkreq: *align(1) const BlockRequest = @ptrCast(requests[0].as_ro().ptr);
        const status: []u8 = requests[2].as_rw() orelse {
            log.err("status descriptor is not writable", .{});
            return error.InvalidFormat;
        };

        const kind = std.enums.fromInt(BlockRequestKind, blkreq.kind) orelse {
            log.warn("unsupported request kind {}", .{blkreq.kind});

            status[0] = VIRTIO_BLK_S_UNSUPP;
            return @truncate(1);
        };

        switch (kind) {
            .Read => {
                const to_write = requests[1].as_rw() orelse {
                    log.err("read data descriptor is not writable", .{});
                    status[0] = VIRTIO_BLK_S_IOERR;
                    return error.InvalidFormat;
                };

                const len = self.file.readPositionalAll(io, to_write, blkreq.sector * 512) catch {
                    status[0] = VIRTIO_BLK_S_IOERR;
                    return 1;
                };

                status[0] = VIRTIO_BLK_S_OK;

                // Account for status write
                return @truncate(len + 1);
            },
            .Write => {
                const to_read = requests[1].as_ro();

                _ = self.file.writePositionalAll(io, to_read, blkreq.sector * 512) catch {
                    status[0] = VIRTIO_BLK_S_IOERR;
                    return 1;
                };

                status[0] = VIRTIO_BLK_S_OK;

                return @truncate(1);
            },
            .Flush => {
                self.file.sync(io) catch {
                    status[0] = VIRTIO_BLK_S_IOERR;
                    return 1;
                };

                status[0] = VIRTIO_BLK_S_OK;
                return 1;
            },
            .GetId => {
                const diskid: [:0]const u8 = "zvirt-disk0";
                const to_write = requests[1].as_rw() orelse {
                    log.err("device ID descriptor is not writable", .{});
                    status[0] = VIRTIO_BLK_S_IOERR;
                    return error.InvalidFormat;
                };

                @memcpy(to_write[0..diskid.len], diskid);

                status[0] = VIRTIO_BLK_S_OK;
                return 1 + diskid.len;
            },
        }
    }

    pub fn read_config(self: *Self, offset: u32) u32 {
        return std.mem.readInt(u32, std.mem.asBytes(&self.config)[offset..][0..4], .little);
    }
};
