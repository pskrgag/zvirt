//! Serializable vector

const std = @import("std");
const serializer = @import("serializer.zig");
const Writer = std.Io.Writer;
const Reader = std.Io.Reader;

pub fn SerializableList(comptime Element: type) type {
    return struct {
        list: std.ArrayList(Element) = .empty,

        const Self = @This();

        pub fn serialize(self: Self, writer: *Writer) !void {
            try serializer.serialize([]const Element, self.list.items, writer);
        }

        pub fn deserialize(reader: *Reader, alloc: std.mem.Allocator) !Self {
            const items = try serializer.deserialize([]Element, reader, alloc);

            return .{
                .list = std.ArrayList(Element).fromOwnedSlice(items),
            };
        }

        pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
            self.list.deinit(alloc);
        }
    };
}
