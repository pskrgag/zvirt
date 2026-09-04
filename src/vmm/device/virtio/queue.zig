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
    ready: u32 = 0,
    elements: u32 = MAX_QUEUE_ELEMENTS,

    last_avail_idx: usize = 0,
    next_used_idx: u16 = 0,

    // Invalid PA
    //
    // TODO: introduce PA abstraction one day...
    desc_ring: u64 = std.math.maxInt(u64),
    available_ring: u64 = std.math.maxInt(u64),
    used_ring: u64 = std.math.maxInt(u64),

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
        mem: *GuestMemory,
        descriptor_head: u16,
        written_len: u32,
    ) bool {
        const header = self.get_used_ring(mem) orelse return false;
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

    pub fn kick(self: *Self, mem: *GuestMemory, alloc: std.mem.Allocator) !std.ArrayList(RequestChain) {
        var res = try std.ArrayList(RequestChain).initCapacity(alloc, 0);
        const avail_header = self.avail_ring(mem) orelse return res;
        const slots = avail_header.slots(self.elements);
        const dring = self.descr_ring(mem) orelse return res;

        while (self.last_avail_idx != avail_header.idx.load(.acquire)) {
            const slot = self.last_avail_idx % self.elements;
            const descriptor_head = slots[slot];

            self.last_avail_idx +%= 1;

            std.debug.print("head {}\n", .{descriptor_head});
            std.debug.print("desr {}\n", .{dring[descriptor_head]});

            try res.append(alloc, self.process_descriptor_chain(descriptor_head, mem, dring).?);
        }

        return res;
    }
};
