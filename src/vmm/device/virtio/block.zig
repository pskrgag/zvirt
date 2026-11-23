//! Virtio block device

const std = @import("std");
const queue = @import("queue.zig");
const log = std.log.scoped(.virtio_blk);
const FileEngine = @import("utils").FileEngine.FileEngine;
const IdAllocator = @import("utils").IdAlloc.IdAllocator;
const PciClass = @import("../pci/config.zig").PciClass;
const VirtioCore = @import("root.zig").VirtioCore;
const NotifyResult = @import("root.zig").NotifyResult;
const EventSources = @import("event_source.zig").EventSources;
const Vm = @import("../../root.zig").Vm;
const GuestMemory = @import("../../memory.zig").GuestMemory;
const LatencyStat = @import("../../stat/root.zig").LatencyStat;
const Device = @import("../root.zig").Device;
const Requests = @import("queue.zig").Requests;

pub const c = @import("linux_abi");

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
    core: VirtioCore,
    notify_latency: LatencyStat = .{},
    io_latency: LatencyStat = .{},
    dev: Device,

    pub const MMIO_TYPE = 0x2;

    pub const PCI_DEVICE_ID = 0x1042;
    pub const PCI_SUBCLASS = 0x0;
    pub const PCI_CLASS: PciClass = .Storage;

    const Self = @This();

    fn read_latency(context: *anyopaque, name: []const u8, io: std.Io) !LatencyStat.Latency {
        const self: *Self = @ptrCast(@alignCast(context));

        if (std.mem.eql(u8, name, "notify"))
            return self.notify_latency.read(io);

        if (std.mem.eql(u8, name, "io"))
            return self.io_latency.read(io);

        return error.InvalidLatency;
    }

    pub const State = struct {
        config: c.virtio_blk_config,
        core: VirtioCore.State,
        async: bool,
    };

    pub fn new(
        name: []const u8,
        path: []const u8,
        num_queues: usize,
        async: bool,
        alloc: std.mem.Allocator,
        io: std.Io,
    ) !*Self {
        const self = try alloc.create(Self);
        errdefer alloc.destroy(self);

        var config = std.mem.zeroes(c.virtio_blk_config);
        var engine = if (async)
            try FileEngine.new_async(MAX_IN_FLIGHT_REQUESTS)
        else
            try FileEngine.new_sync();

        errdefer engine.deinit();

        var file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
        errdefer file.close(io);

        const queues = if (async) 1 else num_queues;

        const stat = try file.stat(io);
        config.capacity = stat.size / 512;
        config.num_queues = @truncate(queues);

        self.* = .{
            .config = config,
            .file = file,
            .engine = engine,
            .core = try VirtioCore.new(Self.features(), queues),
            .dev = .{ .name = name, .context = self, .read_latency = read_latency },
        };
        return self;
    }

    pub fn snapshot(self: *const Self) !State {
        if (self.engine.is_async())
            @panic("Async is not supported");

        // At that point VM is stopped and all events are processed.
        return .{
            .config = self.config,
            .core = self.core.snapshot(),
            .async = self.engine.is_async(),
        };
    }

    pub fn from_snapshot(
        name: []const u8,
        snap: *const State,
        path: []const u8,
        memory: *GuestMemory,
        alloc: std.mem.Allocator,
        io: std.Io,
    ) !*Self {
        const self = try alloc.create(Self);
        errdefer alloc.destroy(self);

        var engine = if (!snap.async)
            try FileEngine.new_sync()
        else
            try FileEngine.new_sync();
        errdefer engine.deinit();

        std.debug.assert(!snap.async or snap.config.num_queues == 1);

        var file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
        errdefer file.close(io);

        self.* = .{
            .config = snap.config,
            .file = file,
            .engine = engine,
            .core = try VirtioCore.from_snapshot(&snap.core, memory),
            .dev = .{ .name = name, .context = self, .read_latency = read_latency },
        };
        return self;
    }

    pub fn completion_event_source(self: *const Self) ?EventSources(1) {
        return .{
            .entries = .{.{ .fd = self.engine.event_source() orelse return null, .edge = false }},
            .count = 1,
        };
    }

    pub fn deinit(self: *Self, alloc: std.mem.Allocator, io: std.Io) void {
        self.core.deinit();
        self.engine.deinit();
        self.file.close(io);
        alloc.destroy(self);
    }

    pub fn handle_completion_event(self: *Self, id: usize, io: std.Io) !NotifyResult {
        _ = id;
        _ = try self.engine.ack_event();

        // NOTE: support only one queue in async mode (do we need more? I don't think so)
        std.debug.assert(self.max_queues() == 1);

        var consumed = false;
        var batch: usize = 0;

        const token = try self.core.get_queue(0, io);
        var notify = false;

        defer self.core.unlock_queue(token, io);

        while (try self.pop_completion()) |async_result| {
            notify |= token.queue.push_used(
                async_result.head,
                async_result.len,
            );

            batch += 1;
            consumed = true;
        }

        if (consumed) {
            log.debug("batched {}\n", .{batch});
        }

        return .{ .notify = notify, .queue = 0 };
    }

    pub fn handle_notify(self: *Self, queue_idx: u19, vm: *Vm, io: std.Io) !NotifyResult {
        var nlatency = self.notify_latency.track();
        defer nlatency.deinit(io);

        const token = try self.core.notified_queue(queue_idx, io);
        defer self.core.unlock_queue(token, io);

        // NOTE: fix zig fucking insanity. Even tho Requests request is said to be undefined
        // zig emits fucking memset.
        var reqs: Requests = undefined;
        reqs.count = 0;

        try token.queue.kick(vm.archvm.memory, &reqs);

        {
            var iolatency = self.io_latency.track();
            defer iolatency.deinit(io);

            self.proccess_requests(reqs.get_requests(), io) catch {
                @panic("todo");
            };
        }

        var notify = false;

        for (reqs.get_requests()) |req| {
            // Len == 0 means that request will be handled in async
            if (req.len != 0) {
                notify |= token.queue.push_used(
                    req.head,
                    req.len,
                );
            }
        }

        return .{ .queue = token.idx, .notify = notify };
    }

    fn pop_completion(self: *Self) !?Completion {
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
