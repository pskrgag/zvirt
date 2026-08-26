//! x86 GDT helpers

const std = @import("std");
const kvm = @import("kvm");

// As per linux requirements
pub const GDT_CODE_INDEX = 2;
pub const GDT_DATA_INDEX = 3;

pub fn selector(index: u16) u16 {
    // Keep RPL (privilage level) and TI (table id) as 0
    return index << 3;
}

pub fn setup_segment(seg: *kvm.Segment, code: bool, index: u16) void {
    // Unused
    seg.base = 0x0;
    // Maximum
    seg.limit = 0xFFFFF;

    // Set long mode
    seg.l = @intFromBool(code);

    // Limit in pages
    seg.g = 0x1;

    // Type of the segment
    seg.type = if (code) 0xb else 0x3;

    // Present
    seg.present = 0x1;

    // Must be 0x0 for long mode
    seg.db = 0x0;

    // Setup selector
    seg.selector = selector(index);
}

const GdtEntry = packed struct(u64) {
    limit: u16,
    base: u24,
    access: u8,
    limit_1: u4,
    flags: u4,
    base_1: u8,
};

pub const Gdt = struct {
    entries: [4]GdtEntry,
};

comptime {
    std.debug.assert(@sizeOf(GdtEntry) == 8);
    std.debug.assert(@sizeOf(Gdt) == 32);
}

// Present | S | RW
const GDT_DATA_ACCESS = (1 << 7) | (1 << 4) | (1 << 1);

// Present | S | E
const GDT_CODE_ACCESS = (1 << 7) | (1 << 4) | (1 << 3);

fn gdt_entry(code: bool) GdtEntry {
    return GdtEntry{
        .limit = 0,
        .limit_1 = 0,
        .base = 0,
        .base_1 = 0,
        .access = if (code) GDT_CODE_ACCESS else GDT_DATA_ACCESS,
        .flags = (1 << 3) | (1 << 1),
    };
}

pub fn gdt() Gdt {
    return .{ .entries = [_]GdtEntry{
        @bitCast(@as(u64, 0)),
        @bitCast(@as(u64, 0)),
        gdt_entry(true),
        gdt_entry(false),
    } };
}
