//! VMM snapshot

const std = @import("std");
const serializer = @import("serializer.zig");

pub fn Snapshot(T: type) type {
    return struct {
        data: T,

        const Self = @This();
        const magic: [5]u8 = .{ 0xda, 0xda, 0xda, 0xda, 0xba };

        pub fn new(data: T) Self {
            return .{ .data = data };
        }

        pub fn serialize(self: *const Self, writer: *std.Io.Writer) !void {
            try writer.writeAll(&magic);
            try serializer.serialize(T, self.data, writer);
        }

        pub fn deserialize(reader: *std.Io.Reader, alloc: std.mem.Allocator) !Self {
            var encoded_magic: [magic.len]u8 = undefined;
            try reader.readSliceAll(&encoded_magic);
            if (!std.mem.eql(u8, &encoded_magic, &magic)) {
                return error.InvalidMagic;
            }

            return .{ .data = try serializer.deserialize(T, reader, alloc) };
        }
    };
}
