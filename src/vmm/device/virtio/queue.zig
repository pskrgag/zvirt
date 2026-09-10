//! Virtio queue

// available -> written by the driver
// used -> written by the device

const std = @import("std");
const GuestMemory = @import("../../memory.zig").GuestMemory;
const Value = std.atomic.Value;

const DESC_F_NEXT: u16 = 1;
const DESC_F_WRITE: u16 = 2;
const DESC_F_INDIRECT: u16 = 4;

const Descriptor = extern struct {
    address: u64,
    length: u32,
    flags: u16,
    next: u16,
};

const AvailableRing = extern struct {
    flags: u16,
    idx: Value(u16),

    fn slots(self: *AvailableRing, elems: usize) []u16 {
        const entries: [*]u16 = @ptrFromInt(
            @intFromPtr(self) + @sizeOf(AvailableRing),
        );

        return entries[0..elems];
    }
};

const UsedRingHeader = extern struct {
    flags: u16,
    idx: Value(u16),

    fn slots(self: *UsedRingHeader, elems: usize) []UsedElement {
        const entries: [*]UsedElement = @ptrFromInt(
            @intFromPtr(self) + @sizeOf(UsedRingHeader),
        );

        return entries[0..elems];
    }
};

const UsedElement = extern struct {
    id: u32,
    len: u32,
};

pub const Request = union(enum) {
    ReadOnly: []const u8,
    WriteOnly: []u8,

    pub fn len(self: *const Request) usize {
        return switch (self.*) {
            .ReadOnly => |v| v.len,
            .WriteOnly => |v| v.len,
        };
    }

    pub fn as_ro(self: *const Request) []const u8 {
        return switch (self.*) {
            .ReadOnly => |v| v,
            .WriteOnly => |v| v,
        };
    }

    pub fn as_rw(self: *const Request) ?[]u8 {
        return switch (self.*) {
            .ReadOnly => null,
            .WriteOnly => |v| v,
        };
    }
};

pub const RequestChain = struct {
    requests: [16]Request = undefined,
    count: usize = 0,
    head: u16,
    len: u32 = 0,

    pub fn push(self: *RequestChain, req: Request) void {
        if (self.count == self.requests.len)
            @panic("Too many requests");

        self.requests[self.count] = req;
        self.count += 1;
    }

    pub fn get_requests(self: *const RequestChain) []const Request {
        return self.requests[0..self.count];
    }
};

pub const MAX_QUEUE_ELEMENTS = 256;

pub const VirtQueue = struct {
    is_ready: u32 = 0,
    elements: u32 = MAX_QUEUE_ELEMENTS,

    last_avail_idx: u16 = 0,
    next_used_idx: u16 = 0,

    // Invalid PA
    //
    // TODO: introduce PA abstraction one day...
    desc_ring: u64 = std.math.maxInt(u64),
    available_ring: u64 = std.math.maxInt(u64),
    used_ring: u64 = std.math.maxInt(u64),

    used_ring_ptr: *UsedRingHeader = undefined,
    descr_ring_ptr: []Descriptor = undefined,
    avail_ring_ptr: *AvailableRing = undefined,

    const Self = @This();

    fn get_used_ring(self: *Self, mem: *GuestMemory) ?*UsedRingHeader {
        const used_ring_size = self.elements * @sizeOf(UsedElement) +
            @sizeOf(UsedRingHeader);
        const ring = mem.as_slice(self.used_ring, used_ring_size) orelse return null;
        const header: *UsedRingHeader = @ptrCast(@alignCast(ring.ptr));

        return header;
    }

    pub fn push_used(
        self: *Self,
        descriptor_head: u16,
        written_len: u32,
    ) bool {
        const header = self.used_ring_ptr;
        const slots = header.slots(self.elements);
        const slot = self.next_used_idx % @as(u16, @intCast(self.elements));

        slots[slot] = .{
            .id = descriptor_head,
            .len = written_len,
        };

        self.next_used_idx +%= 1;
        header.idx.store(self.next_used_idx, .release);
        return true;
    }

    fn avail_ring(self: *Self, mem: *GuestMemory) ?*AvailableRing {
        const avail_ring_size = self.elements * @sizeOf(u16) + @sizeOf(AvailableRing);
        const ring = mem.as_slice(self.available_ring, avail_ring_size) orelse return null;
        const header: *AvailableRing = @ptrCast(@alignCast(ring.ptr));

        return header;
    }

    fn descr_ring(self: *Self, mem: *GuestMemory) ?[]Descriptor {
        const dring_size = self.elements * @sizeOf(Descriptor);
        const ring = mem.as_slice(self.desc_ring, dring_size) orelse return null;
        const header: [*]Descriptor = @ptrCast(@alignCast(ring.ptr));

        return header[0..self.elements];
    }

    fn process_descriptor_chain(
        self: *Self,
        head: u16,
        mem: *GuestMemory,
        dring: []Descriptor,
    ) ?RequestChain {
        var remaining = self.elements;
        var descriptor_idx = head;
        var chain = RequestChain{ .head = head };

        while (true) {
            if (descriptor_idx >= self.elements)
                return null;

            if (remaining == 0)
                return null;

            remaining -= 1;

            const descriptor = dring[descriptor_idx];

            const slice = mem.as_slice(
                descriptor.address,
                descriptor.length,
            ) orelse return null;

            const req = if (descriptor.flags & DESC_F_WRITE == 0)
                Request{ .ReadOnly = slice }
            else
                Request{ .WriteOnly = slice };

            chain.push(req);

            if (descriptor.flags & DESC_F_NEXT == 0)
                break;

            descriptor_idx = descriptor.next;
        }

        return chain;
    }

    pub fn ready(self: *Self, mem: *GuestMemory, is_ready: u32) !void {
        if (is_ready != 0) {
            self.avail_ring_ptr = self.avail_ring(mem) orelse return error.InvalidAddr;
            self.descr_ring_ptr = self.descr_ring(mem) orelse return error.InvalidAddr;
            self.used_ring_ptr = self.get_used_ring(mem) orelse return error.InvalidAddr;
        }

        self.is_ready = is_ready;
    }

    pub fn kick(self: *Self, mem: *GuestMemory, alloc: std.mem.Allocator) !std.ArrayList(RequestChain) {
        var res = try std.ArrayList(RequestChain).initCapacity(alloc, 0);
        const slots = self.avail_ring_ptr.slots(self.elements);

        while (self.last_avail_idx != self.avail_ring_ptr.idx.load(.acquire)) {
            const slot = self.last_avail_idx % self.elements;
            const descriptor_head = slots[slot];

            self.last_avail_idx +%= 1;

            try res.append(alloc, self.process_descriptor_chain(
                descriptor_head,
                mem,
                self.descr_ring_ptr,
            ).?);
        }

        return res;
    }
};

test "kick returns a descriptor chain in descriptor order" {
    const alloc = std.testing.allocator;
    var ram: [4096]u8 align(16) = @splat(0);
    const mem = try GuestMemory.new(alloc);
    defer mem.deinit(alloc);
    try mem.add(0, &ram, false, alloc);

    var queue = VirtQueue{
        .elements = 8,
        .desc_ring = 0x100,
        .available_ring = 0x200,
        .used_ring = 0x300,
    };

    const descriptors = queue.descr_ring(mem).?;
    descriptors[0] = .{
        .address = 0x400,
        .length = 16,
        .flags = DESC_F_NEXT,
        .next = 3,
    };
    descriptors[3] = .{
        .address = 0x500,
        .length = 32,
        .flags = DESC_F_NEXT | DESC_F_WRITE,
        .next = 5,
    };
    descriptors[5] = .{
        .address = 0x600,
        .length = 1,
        .flags = DESC_F_WRITE,
        .next = 0,
    };

    const available = queue.avail_ring(mem).?;
    available.* = .{ .flags = 0, .idx = Value(u16).init(0) };
    available.slots(queue.elements)[0] = 0;
    available.idx.store(1, .release);

    try queue.ready(mem, 1);

    var chains = try queue.kick(mem, alloc);
    defer chains.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), chains.items.len);
    try std.testing.expectEqual(@as(u16, 0), chains.items[0].head);

    const requests = chains.items[0].get_requests();
    try std.testing.expectEqual(@as(usize, 3), requests.len);
    try std.testing.expectEqual(@as(usize, 16), requests[0].len());
    try std.testing.expect(requests[0].as_rw() == null);
    try std.testing.expectEqual(@as(usize, 32), requests[1].as_rw().?.len);
    try std.testing.expectEqual(@as(usize, 1), requests[2].as_rw().?.len);
    try std.testing.expectEqual(@intFromPtr(&ram[0x400]), @intFromPtr(requests[0].as_ro().ptr));
    try std.testing.expectEqual(@intFromPtr(&ram[0x500]), @intFromPtr(requests[1].as_ro().ptr));
    try std.testing.expectEqual(@intFromPtr(&ram[0x600]), @intFromPtr(requests[2].as_ro().ptr));
}

test "kick consumes each available entry once" {
    const alloc = std.testing.allocator;
    var ram: [4096]u8 align(16) = @splat(0);
    const mem = try GuestMemory.new(alloc);
    defer mem.deinit(alloc);
    try mem.add(0, &ram, false, alloc);

    var queue = VirtQueue{
        .elements = 8,
        .desc_ring = 0x100,
        .available_ring = 0x200,
        .used_ring = 0x300,
    };

    const descriptors = queue.descr_ring(mem).?;
    descriptors[0] = .{ .address = 0x400, .length = 4, .flags = 0, .next = 0 };
    descriptors[1] = .{ .address = 0x500, .length = 8, .flags = 0, .next = 0 };

    const available = queue.avail_ring(mem).?;
    available.* = .{ .flags = 0, .idx = Value(u16).init(0) };
    available.slots(queue.elements)[0] = 0;
    available.slots(queue.elements)[1] = 1;
    available.idx.store(2, .release);

    try queue.ready(mem, 1);

    var first = try queue.kick(mem, alloc);
    defer first.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), first.items.len);
    try std.testing.expectEqual(@as(u16, 0), first.items[0].head);
    try std.testing.expectEqual(@as(u16, 1), first.items[1].head);
    try std.testing.expectEqual(@as(usize, 2), queue.last_avail_idx);

    var second = try queue.kick(mem, alloc);
    defer second.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), second.items.len);
}

test "push_used publishes used elements and advances idx" {
    const alloc = std.testing.allocator;
    var ram: [4096]u8 align(16) = @splat(0);
    const mem = try GuestMemory.new(alloc);

    defer mem.deinit(alloc);
    try mem.add(0, &ram, false, alloc);

    var queue = VirtQueue{
        .elements = 8,
        .desc_ring = 0x100,
        .available_ring = 0x200,
        .used_ring = 0x300,
    };

    try queue.ready(mem, 1);

    const used = queue.get_used_ring(mem).?;
    used.* = .{ .flags = 0, .idx = Value(u16).init(0) };

    try std.testing.expect(queue.push_used(7, 513));
    try std.testing.expectEqual(@as(u16, 1), used.idx.load(.acquire));
    try std.testing.expectEqual(@as(u32, 7), used.slots(queue.elements)[0].id);
    try std.testing.expectEqual(@as(u32, 513), used.slots(queue.elements)[0].len);

    try std.testing.expect(queue.push_used(3, 1));
    try std.testing.expectEqual(@as(u16, 2), used.idx.load(.acquire));
    try std.testing.expectEqual(@as(u32, 3), used.slots(queue.elements)[1].id);
    try std.testing.expectEqual(@as(u32, 1), used.slots(queue.elements)[1].len);
}
