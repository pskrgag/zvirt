//! ACPI helpers

const std = @import("std");

pub const rsdt = @import("rsdt.zig");
pub const xsdt = @import("xsdt.zig");
pub const madt = @import("madt.zig");

pub const AcpiTableHeader = extern struct {
    /// ASCII table signature
    signature: [4]u8,

    /// Length of table in bytes, including this header
    length: u32 align(1),

    /// ACPI Specification minor version number
    revision: u8,

    /// To make sum of entire table == 0
    checksum: u8,

    /// ASCII OEM identification
    oem_id: [6]u8 = "ZVIRT ".*,

    /// ASCII OEM table identification
    oem_table_id: [8]u8 = "ZVIRTVMM".*,

    /// OEM revision number
    oem_revision: u32 align(1) = 1,

    /// ASCII ASL compiler vendor ID
    asl_compiler_id: [4]u8 = "ZIG ".*,

    /// ASL compiler version
    asl_compiler_revision: u32 align(1) = 1,
};

pub const AcpiSubtableHeader = extern struct {
    /// MADT subtable type
    kind: u8,

    /// Total subtable length, including this header
    length: u8,
};

pub fn checksum(arrays: []const []const u8) u8 {
    var sum: u8 = 0;

    for (arrays) |arr| {
        for (arr) |i| {
            sum +%= i;
        }
    }

    return @intCast((256 - @as(u16, sum)) % 256);
}

comptime {
    std.debug.assert(@sizeOf(AcpiTableHeader) == 36);
}
