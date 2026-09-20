//! MSI-X interrupts support

const std = @import("std");
const PciDeviceCore = @import("root.zig").PciDeviceCore;
const PciBus = @import("root.zig").PciBus;
const Vm = @import("../../root.zig").Vm;

const log = std.log.scoped(.pci_msix);

const MessageControl = packed struct(u16) {
    table_count: u11,
    _reserved: u3 = 0,
    mask_all: u1 = 0,
    msix_enalbe: u1 = 0,
};

const TableAddress = packed struct(u32) {
    bar: u3,
    offset: u29,
};

pub const TableEntry = packed struct {
    address_low: u32 = 0,
    address_high: u32 = 0,
    data: u32 = 0,

    // Masked by default
    vector: u32 = 1,
};

const pci_msix_cap = packed struct {
    cap_vndr: u8 = 0x11,
    cap_next: u8 = 0,
    msg_control: MessageControl,
    table: TableAddress,
    pending_bit_array: TableAddress,
};

const TableCountType = @FieldType(MessageControl, "table_count");
const MAX_IRQS = std.math.maxInt(TableCountType);

pub const Msix = struct {
    max_irqs: usize,
    table: [MAX_IRQS]TableEntry = @splat(.{}),
    cap: usize,
    mutex: std.Io.Mutex = .init,

    const Self = @This();

    pub fn new(core: *PciDeviceCore, max_irqs: usize, alloc: std.mem.Allocator) !*Self {
        const self = try alloc.create(Self);
        errdefer alloc.destroy(self);

        if (max_irqs > MAX_IRQS)
            return error.InvalidNumberOfIrqs;

        const bar: u8 = try core.allocate_bar(.{
            .context = self,
            .read_fn = mmio_read,
            .write_fn = mmio_write,
        });

        const table_size = max_irqs * @sizeOf(TableEntry);
        const cap = pci_msix_cap{
            .msg_control = .{
                .table_count = @as(TableCountType, @truncate(max_irqs)) - 1,
            },
            .table = .{ .bar = @truncate(bar), .offset = 0 },
            .pending_bit_array = .{ .bar = @truncate(bar), .offset = @truncate(table_size) },
        };

        self.* = .{
            .max_irqs = max_irqs,
            .cap = try core.config.add_capability(std.mem.asBytes(&cap)),
        };

        core.config.set_write_write_mask(u16, 3 << 14, self.cap + 2);
        return self;
    }

    pub fn is_enabled(self: *Self, core: *PciDeviceCore, io: std.Io) bool {
        const control = core.read_config(u16, @intCast(self.cap + 2), io) catch {
            @panic("Corrupted config space?");
        };

        return (control & (1 << 15)) != 0 and (control & (1 << 14)) == 0;
    }

    pub fn signal(self: *Self, core: *PciDeviceCore, idx: usize, vm: *Vm, io: std.Io) !void {
        if (idx >= self.table.len)
            return error.OutOfBounds;

        if (!self.is_enabled(core, io)) {
            return;
        }

        const entry = blk: {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);

            break :blk self.table[idx];
        };

        if (entry.vector & 1 != 0) {
            return;
        }

        try vm.msi_signal(entry.address_low, entry.address_high, entry.data);
    }

    fn handle_table_write(self: *Self, offset: usize, data: []const u8, io: std.Io) !void {
        // only one entry for now
        std.debug.assert(offset % 4 == 0);
        std.debug.assert(data.len == 4);

        try self.mutex.lock(io);
        defer self.mutex.unlock(io);

        const val = std.mem.readInt(u32, data[0..@sizeOf(u32)], .little);

        const idx = offset / @sizeOf(TableEntry);
        const off = offset % @sizeOf(TableEntry);

        switch (off) {
            0 => self.table[idx].address_low = val,
            4 => self.table[idx].address_high = val,
            8 => self.table[idx].data = val,
            12 => self.table[idx].vector = val,
            else => unreachable,
        }
    }

    fn handle_table_read(self: *Self, offset: usize, io: std.Io) !u32 {
        // only one entry for now
        std.debug.assert(offset % 4 == 0);

        try self.mutex.lock(io);
        defer self.mutex.unlock(io);

        const idx = offset / @sizeOf(TableEntry);
        const off = offset % @sizeOf(TableEntry);

        return std.mem.readInt(u32, std.mem.asBytes(&self.table[idx])[off..][0..4], .little);
    }

    fn mmio_read(_self: *anyopaque, offset: usize, data: []u8, io: std.Io) !void {
        var self: *Self = @ptrCast(@alignCast(_self));
        const pba_offset = self.max_irqs * @sizeOf(TableEntry);

        std.debug.assert(data.len == 4);
        log.debug("read from 0x{x}, data {x}\n", .{ offset, data });

        const val = if (offset < pba_offset)
            try self.handle_table_read(offset, io)
        else
            @panic("todo");

        std.mem.writeInt(u32, data[0..4], val, .little);
    }

    fn mmio_write(_self: *anyopaque, offset: usize, data: []const u8, io: std.Io) !void {
        var self: *Self = @ptrCast(@alignCast(_self));
        const pba_offset = self.max_irqs * @sizeOf(TableEntry);

        log.debug("write from 0x{x}, data {x}\n", .{ offset, data });
        if (offset < pba_offset) {
            try self.handle_table_write(offset, data, io);
        } else {
            @panic("todo");
        }
    }

    pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
        alloc.destroy(self);
    }
};

comptime {
    std.debug.assert(@sizeOf(TableEntry) == 16);
}
