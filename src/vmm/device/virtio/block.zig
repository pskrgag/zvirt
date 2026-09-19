//! Virtio block device

const std = @import("std");
const queue = @import("queue.zig");
const log = std.log.scoped(.virtio_blk);
const FileEngine = @import("../../io/root.zig").FileEngine;
const IdAllocator = @import("utils").IdAlloc.IdAllocator;
const PciClass = @import("../pci/config.zig").PciClass;

pub const c = @cImport({
    @cInclude("linux/virtio_blk.h");
});

const VIRTIO_BLK_F_RO: u32 = 1 << 5;
const VIRTIO_BLK_F_MQ: u32 = 1 << 12;

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

const MAX_IN_FLIGHT_REQUESTS = 128;

const Token = packed struct(u64) {
    status: u48,
    head: u16,
};

comptime {
    std.debug.assert(@sizeOf(Token) <= @sizeOf(u64));
}

pub const Block = struct {
    pub const Completion = struct {
        head: u16,
        len: u32,
    };

    config: c.virtio_blk_config,
    file: std.Io.File,
    engine: FileEngine,

    pub const MMIO_TYPE = 0x2;

    pub const PCI_DEVICE_ID = 0x1042;
    pub const PCI_SUBCLASS = 0x0;
    pub const PCI_CLASS: PciClass = .Storage;

    const Self = @This();

    pub fn new(path: []const u8, num_queues: usize, async: bool, io: std.Io) !Self {
        var config = std.mem.zeroes(c.virtio_blk_config);
        var engine = if (async)
            try FileEngine.new_async(MAX_IN_FLIGHT_REQUESTS)
        else
            try FileEngine.new_sync();

        errdefer engine.deinit();

        var file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
        errdefer file.close(io);

        const stat = try file.stat(io);
        config.capacity = stat.size / 512;
        config.num_queues = @truncate(num_queues);

        return .{
            .config = config,
            .file = file,
            .engine = engine,
        };
    }

    pub fn event_source(self: *const Self) ?std.posix.fd_t {
        return self.engine.event_source();
    }

    pub fn deinit(self: *Self, io: std.Io) void {
        self.engine.deinit();
        self.file.close(io);
    }

    pub fn ack_event(self: *Self) !void {
        _ = try self.engine.ack_event();
    }

    pub fn pop_completion(self: *Self) !?Completion {
        const comp = (try self.engine.pop_completion(u64)) orelse return null;

        const token: Token = @bitCast(comp.token);
        const status: [*]u8 = @ptrFromInt(token.status);

        log.debug("Async event finished {}\n", .{comp});

        var len: u32 = 1;
        if (comp.res > 0) {
            status[0] = VIRTIO_BLK_S_OK;
            len = @as(u32, @intCast(comp.res)) + 1;
        } else {
            status[0] = VIRTIO_BLK_S_IOERR;
        }

        return .{ .head = token.head, .len = len };
    }

    pub fn features() u32 {
        return VIRTIO_BLK_F_MQ;
    }

    pub fn max_queues(self: *const Self) u32 {
        return self.config.num_queues;
    }

    pub fn proccess_requests(self: *Self, reqs: []queue.RequestChain, io: std.Io) !void {
        var try_submit = false;

        for (reqs) |*req| {
            req.len = (try self.proccess_request(req, io)) orelse 0;
            try_submit |= (req.len == 0);
        }

        if (try_submit) {
            try self.engine.submit();
        }
    }

    fn proccess_request(self: *Self, req: *const queue.RequestChain, io: std.Io) !?u32 {
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

                std.debug.assert(@intFromPtr(status.ptr) <= std.math.maxInt(@FieldType(Token, "status")));
                const token = Token{
                    .status = @truncate(@intFromPtr(status.ptr)),
                    .head = req.head,
                };
                const value: u64 = @bitCast(token);

                const res = self.engine.read(self.file.handle, to_write, blkreq.sector * 512, value) catch {
                    status[0] = VIRTIO_BLK_S_IOERR;
                    return @truncate(1);
                };

                if (res) |r| {
                    status[0] = VIRTIO_BLK_S_OK;
                    return @truncate(r + 1);
                }

                return null;
            },
            .Write => {
                const to_read = requests[1].as_ro();

                std.debug.assert(@intFromPtr(status.ptr) <= std.math.maxInt(@FieldType(Token, "status")));
                const token = Token{
                    .status = @truncate(@intFromPtr(status.ptr)),
                    .head = req.head,
                };
                const value: u64 = @bitCast(token);

                const res = self.engine.write(self.file.handle, to_read, blkreq.sector * 512, value) catch {
                    status[0] = VIRTIO_BLK_S_IOERR;
                    return @truncate(1);
                };

                if (res) |_| {
                    status[0] = VIRTIO_BLK_S_OK;
                    return @truncate(1);
                }

                return null;
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

    pub fn read_config(self: *const Self, offset: u32) u32 {
        return std.mem.readInt(u32, std.mem.asBytes(&self.config)[offset..][0..4], .little);
    }
};
