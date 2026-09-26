//! Device MAC

const std = @import("std");

pub const Mac = struct {
    mac: [6]u8,

    const Self = @This();

    pub fn from_bytes(mac: [6]u8) Self {
        return .{ .mac = mac };
    }

    // Expect ff:ee:dd:cc:bb:aa format
    pub fn from_str(data: []const u8) !Self {
        var parts = std.mem.splitScalar(u8, data, ':');
        var mac: [6]u8 = undefined;
        var octets: usize = 0;

        while (parts.next()) |part| {
            if (part.len != 2)
                return error.WrongFormat;

            if (octets >= 6)
                return error.InvalidNumberOfOctets;

            mac[octets] = try std.fmt.parseInt(u8, part, 16);
            octets += 1;
        }

        if (octets != 6)
            return error.InvalidNumberOfOctets;

        return .{ .mac = mac };
    }
};

test "Parsing " {
    {
        const mac = try Mac.from_str("11:11:11:11:11:11");

        try std.testing.expectEqualSlices(u8, &mac.mac, &[_]u8{0x11} ** 6);
    }

    {
        try std.testing.expectError(error.InvalidNumberOfOctets, Mac.from_str("11:11:11:11:11"));
        try std.testing.expectError(error.InvalidNumberOfOctets, Mac.from_str("11:11:11:11:11:11:11"));
        try std.testing.expectError(error.WrongFormat, Mac.from_str("11,11,11,11,11"));
    }
}
