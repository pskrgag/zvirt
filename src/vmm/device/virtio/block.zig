//! Virtio block device

const std = @import("std");
const queue = @import("queue.zig");
const log = std.log.scoped(.virtio_blk);
const FileEngine = @import("../../io/root.zig").FileEngine;
const IdAllocator = @import("utils").IdAlloc.IdAllocator;

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

const Token = struct {
    status: [*]u8,
    head: u16,
    len: usize,
};

pub const Block = struct {
    pub const Completion = struct {
        head: u16,
        len: u32,
    };

    config: c.virtio_blk_config,
    file: std.Io.File,
    engine: FileEngine,
    requests: [MAX_IN_FLIGHT_REQUESTS]Token = undefined,
    bitmap: IdAllocator(MAX_IN_FLIGHT_REQUESTS) = .{},

    pub const TYPE = 0x2;

    const Self = @This();

    pub fn new(path: []const u8, io: std.Io) !Self {
        var config = std.mem.zeroes(c.virtio_blk_config);
        var engine = try FileEngine.new(MAX_IN_FLIGHT_REQUESTS);
        errdefer engine.deinit();

        var file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
        errdefer file.close(io);

        const stat = try file.stat(io);
        config.capacity = stat.size / 512;
        config.num_queues = 1;

        return .{
            .config = config,
            .file = file,
            .engine = engine,
        };
    }

    pub fn event_source(self: *const Self) std.posix.fd_t {
        return self.engine.event.as_fd();
    }

    pub fn deinit(self: *Self, io: std.Io) void {
        self.engine.deinit();
        self.file.close(io);
    }

    pub fn ack_event(self: *Self) !void {
        _ = try self.engine.ack_event();
    }

    pub fn pop_completion(self: *Self) !?Completion {
        const comp = (try self.engine.pop_completion(usize)) orelse return null;

        const token = &self.requests[comp.token];
        defer self.bitmap.free(comp.token);

        log.debug("Async event finished {}\n", .{comp});

        var len: u32 = 1;
        if (comp.res > 0) {
            token.status[0] = VIRTIO_BLK_S_OK;
            len = @as(u32, @intCast(comp.res)) + 1;
        } else {
            token.status[0] = VIRTIO_BLK_S_IOERR;
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

                const id = self.bitmap.allocate() orelse @panic("todo");

                self.requests[id].status = status.ptr;
                self.requests[id].head = req.head;

                errdefer self.bitmap.free(id);

                try self.engine.register_read(self.file.handle, to_write, blkreq.sector * 512, id);
                log.debug("Registered async read {}\n", .{id});
                return null;
            },
            .Write => {
                const to_read = requests[1].as_ro();

                const id = self.bitmap.allocate() orelse @panic("todo");

                self.requests[id].status = status.ptr;
                self.requests[id].head = req.head;

                errdefer self.bitmap.free(id);

                try self.engine.register_write(self.file.handle, to_read, blkreq.sector * 512, id);
                log.debug("Registered async write {}\n", .{id});
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

    pub fn read_config(self: *Self, offset: u32) u32 {
        return std.mem.readInt(u32, std.mem.asBytes(&self.config)[offset..][0..4], .little);
    }
};
