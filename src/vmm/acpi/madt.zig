//! MADT helpers

const std = @import("std");
const AcpiTableHeader = @import("root.zig").AcpiTableHeader;
const AcpiSubtableHeader = @import("root.zig").AcpiSubtableHeader;
const checksum = @import("root.zig").checksum;

const LOCAL_APIC_ADDRESS: u32 = 0xfee0_0000;
const IO_APIC_ADDRESS: u32 = 0xfec0_0000;
const PCAT_COMPAT: u32 = 1 << 0;

pub const AcpiTableMadt = extern struct {
    /// Common ACPI table header; signature must be "APIC"
    header: AcpiTableHeader,

    /// Physical address of the local APIC
    address: u32 align(1) = LOCAL_APIC_ADDRESS,

    /// Bit 0: system also has dual 8259 PICs
    flags: u32 align(1) = PCAT_COMPAT,

    const Self = @This();

    pub fn size_with_cpus(cpus: usize) u32 {
        return @intCast(@sizeOf(Self) +
            cpus * @sizeOf(AcpiMadtLocalApic) +
            @sizeOf(AcpiMadtIoApic));
    }

    pub fn local_apics(self: *Self, count: usize) []align(1) AcpiMadtLocalApic {
        const address = @intFromPtr(self) + @sizeOf(Self);
        const ptr: [*]align(1) AcpiMadtLocalApic = @ptrFromInt(address);

        return ptr[0..count];
    }

    pub fn io_apic(self: *Self, cpu_count: usize) *align(1) AcpiMadtIoApic {
        const address = @intFromPtr(self) +
            @sizeOf(Self) +
            cpu_count * @sizeOf(AcpiMadtLocalApic);

        return @ptrFromInt(address);
    }

    pub fn init(self: *Self, cpu_count: usize) void {
        std.debug.assert(cpu_count <= std.math.maxInt(u8));

        self.* = .{
            .header = .{
                .signature = "APIC".*,
                .length = Self.size_with_cpus(cpu_count),
                .revision = 1,
                .checksum = 0,
            },
        };

        for (self.local_apics(cpu_count), 0..) |*local_apic, cpu| {
            local_apic.* = .{
                .processor_id = @intCast(cpu),
                .id = @intCast(cpu),
            };
        }

        self.io_apic(cpu_count).* = .{
            .id = @intCast(cpu_count),
        };

        const ptr: [*]const u8 = @ptrCast(self);
        self.header.checksum = checksum(&.{ptr[0..self.header.length]});
    }
};

pub const AcpiMadtLocalApic = extern struct {
    /// Header
    header: AcpiSubtableHeader = .{ .kind = 0, .length = 8 },

    /// ACPI processor ID
    processor_id: u8,

    /// Processor's local APIC ID
    id: u8,

    lapic_flags: u32 align(1) = 1 << 0,
};

pub const AcpiMadtIoApic = extern struct {
    /// Header
    header: AcpiSubtableHeader = .{ .kind = 1, .length = 12 },

    /// I/O APIC ID
    id: u8,

    /// Reserved, must be zero
    reserved: u8 = 0,

    /// I/O APIC physical address
    address: u32 align(1) = IO_APIC_ADDRESS,

    /// Global system interrupt where interrupt inputs start
    global_irq_base: u32 align(1) = 0,
};

comptime {
    std.debug.assert(@sizeOf(AcpiTableMadt) == 44);
    std.debug.assert(@sizeOf(AcpiMadtLocalApic) == 8);
    std.debug.assert(@sizeOf(AcpiMadtIoApic) == 12);
}
