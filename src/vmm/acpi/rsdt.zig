//! RSDT helpers

const std = @import("std");
const checksum = @import("root.zig").checksum;

pub const AcpiTableRsdp = extern struct {
    /// ACPI signature, contains "RSD PTR "
    signature: [8]u8 = "RSD PTR ".*,

    /// ACPI 1.0 checksum
    checksum: u8 = 0,

    /// OEM identification
    oem_id: [6]u8 = "zvirt ".*,

    /// Must be 0 for ACPI 1.0 or 2 for ACPI 2.0+
    revision: u8 = 2,

    /// 32-bit physical address of the RSDT
    rsdt_physical_address: u32 align(1),

    /// Table length in bytes, including header (ACPI 2.0+)
    length: u32 align(1) = 36,

    /// 64-bit physical address of the XSDT (ACPI 2.0+)
    xsdt_physical_address: u64 align(1),

    /// Checksum of entire table (ACPI 2.0+)
    extended_checksum: u8 = 0,

    /// Reserved, must be zero
    reserved: [3]u8 = .{ 0, 0, 0 },

    const Self = @This();

    pub fn new(rsdt_pa: u32, xsdt_pa: u32) Self {
        var self = Self{ .xsdt_physical_address = xsdt_pa, .rsdt_physical_address = rsdt_pa };

        self.extended_checksum = checksum(&.{std.mem.asBytes(&self)});
        self.checksum = checksum(&.{std.mem.asBytes(&self)[0..20]});
        return self;
    }
};

comptime {
    std.debug.assert(@sizeOf(AcpiTableRsdp) == 36);
    std.debug.assert(@offsetOf(AcpiTableRsdp, "xsdt_physical_address") == 0x18);
}
