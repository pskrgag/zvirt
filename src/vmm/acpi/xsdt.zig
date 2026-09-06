//! XSTD table

const std = @import("std");
const AcpiTableHeader = @import("root.zig").AcpiTableHeader;
const checksum = @import("root.zig").checksum;

pub const AcpiXstd = extern struct {
    header: AcpiTableHeader,

    const Self = @This();

    pub fn entries(self: *Self, count: usize) []align(1) u64 {
        const address = @intFromPtr(self) + @sizeOf(Self);
        const ptr: [*]align(1) u64 = @ptrFromInt(address);

        return ptr[0..count];
    }

    pub fn size_with_entries(count: usize) u32 {
        return @intCast(@sizeOf(Self) + count * @sizeOf(u64));
    }

    pub fn init(self: *Self, pas: []const u64) void {
        var header = AcpiTableHeader{
            .signature = "XSDT".*,
            .length = Self.size_with_entries(pas.len),
            .revision = 2,
            .checksum = 0,
        };

        @memcpy(self.entries(pas.len), pas);

        const data = .{ std.mem.asBytes(&header), std.mem.sliceAsBytes(self.entries(pas.len)) };
        const sum = checksum(&data);

        header.checksum = sum;
        self.header = header;
    }
};
