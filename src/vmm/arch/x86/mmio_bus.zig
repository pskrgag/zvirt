//! x86 MMIO bus

const std = @import("std");
const device = @import("../../device/root.zig");
const Io = std.Io;
const IoResult = @import("kvm").IoResult;
const VirtioMmioDevice = @import("../../device/root.zig").VirtioMmioDevice;
const log = std.log.scoped(.mmio_bus);
const Vm = @import("../../root.zig").Vm;
const MmioDevice = @import("../../device/root.zig").MmioDevice;

pub const MAX_DEVICES = 10;

const Self = @This();
const DeviceTreap = std.Treap(Range, Range.compare);

buffer: [MAX_DEVICES]VirtioMmioDevice,
virtio_devs: std.ArrayList(VirtioMmioDevice),
ranges: DeviceTreap,
alloc: std.mem.Allocator,

const Range = struct {
    start: u64,
    size: usize,

    fn contains(self: *const Range, addr: u64) bool {
        return self.start <= addr and addr < self.start + self.size;
    }

    fn compare(lhs: Range, rhs: Range) std.math.Order {
        std.debug.assert(!lhs.overlaps(&rhs));

        return std.math.order(lhs.start, rhs.start);
    }

    fn overlaps(self: *const Range, other: *const Range) bool {
        const other_end = other.start + other.size;
        const self_end = self.start + self.size;

        return self.start < other_end and other.start < self_end;
    }
};

const TreapNode = struct {
    node: DeviceTreap.Node,
    value: MmioDevice,
};

pub fn handle_event(
    self: *Self,
    id: u29,
    fd: std.posix.fd_t,
    io: std.Io,
) !void {
    try self.virtio_devs.items[id].handle_event(fd, io);
}

pub fn register_range(self: *Self, start: u64, size: usize, mmio_range: MmioDevice) !void {
    const node = try self.alloc.create(TreapNode);
    errdefer self.alloc.destroy(node);

    node.value = mmio_range;

    var iter = self.ranges.inorderIterator();
    const range = Range{ .start = start, .size = size };

    while (iter.next()) |val| {
        if (range.overlaps(&val.key))
            return error.RangeOverlaps;
    }

    var entry = self.ranges.getEntryFor(range);
    entry.set(&node.node);
}

fn find_region(tree: *const DeviceTreap, address: u64) ?*DeviceTreap.Node {
    var current = tree.root;
    var candidate: ?*DeviceTreap.Node = null;

    while (current) |node| {
        if (address < node.key.start) {
            current = node.children[0];
        } else {
            candidate = node;
            current = node.children[1];
        }
    }

    if (candidate) |can| {
        if (can.key.contains(address))
            return can;
    }

    return null;
}

pub fn handle_mmio(self: *Self, mmio_request: anytype, io: std.Io) !?IoResult {
    // log.debug("access: {any}", .{mmio_request});
    switch (mmio_request.pa) {
        0xa0000...0xbffff,
        0xc0000...0xfffff,

        // AMD FCH_PM_S5_RESET_STATUS. It holds last crash reason. Returning -1 means "unsupported"
        // based on print_s5_reset_status_mmio()
        0xfed803c0,
        => return IoResult{ .Mmio = .{ .data = 0xffffffffffffffff } },
        else => {
            const n = find_region(&self.ranges, mmio_request.pa);

            if (n) |node| {
                const entry: *TreapNode = @fieldParentPtr("node", node);
                const offset = mmio_request.pa - node.key.start;

                if (mmio_request.write) {
                    try entry.value.write_fn(
                        entry.value.context,
                        offset,
                        std.mem.asBytes(&mmio_request.data)[0..mmio_request.len],
                        io,
                    );

                    return null;
                } else {
                    var res: u64 = 0;

                    try entry.value.read_fn(
                        entry.value.context,
                        offset,
                        std.mem.asBytes(&res)[0..mmio_request.len],
                        io,
                    );

                    return IoResult{ .Mmio = .{ .data = res } };
                }
            }

            log.err("unhandled MMIO address 0x{x}", .{mmio_request.pa});
            @panic("todo");
        },
    }
}

pub fn deinit(self: *Self, alloc: std.mem.Allocator, io: std.Io) void {
    for (self.virtio_devs.items) |*dev| {
        dev.deinit(io);
    }

    while (self.ranges.getMin()) |node| {
        var entry = self.ranges.getEntryForExisting(node);
        entry.set(null);

        const allocation: *TreapNode = @fieldParentPtr("node", node);
        self.alloc.destroy(allocation);
    }

    alloc.destroy(self);
}

pub fn new(alloc: std.mem.Allocator) !*Self {
    var self = try alloc.create(Self);

    self.virtio_devs = std.ArrayList(VirtioMmioDevice).initBuffer(&self.buffer);
    self.alloc = alloc;
    self.ranges = .{};
    return self;
}

pub fn register_device(self: *Self, vm: *Vm, dev: VirtioMmioDevice) !void {
    const id = self.virtio_devs.items.len;

    try dev.register_events(vm, @truncate(id));
    self.virtio_devs.appendAssumeCapacity(dev);
    const stored_dev = &self.virtio_devs.items[id];
    try self.register_range(stored_dev.base(), 4096, stored_dev.mmio_device());
    // TODO: unregister in case of an error
}
