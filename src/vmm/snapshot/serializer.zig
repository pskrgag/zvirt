//! Stupid serializer to binary

const std = @import("std");
const Writer = std.Io.Writer;
const Reader = std.Io.Reader;
const SerializableList = @import("vector.zig").SerializableList;

pub fn serialize(T: type, val: T, writer: *Writer) !void {
    const type_info = @typeInfo(T);

    switch (type_info) {
        .int, .bool, .float => {
            try writer.writeAll(std.mem.asBytes(&val));
        },
        .array => |info| {
            for (val) |element| {
                try serialize(info.child, element, writer);
            }
        },
        .optional => |info| {
            try serialize(bool, val != null, writer);
            if (val) |value| {
                try serialize(info.child, value, writer);
            }
        },
        .@"struct" => {
            if (@hasDecl(T, "serialize")) {
                return try val.serialize(writer);
            }

            inline for (std.meta.fields(T)) |field| {
                const field_value = @field(val, field.name);

                try serialize(field.type, field_value, writer);
            }
        },
        .pointer => |info| {
            switch (info.size) {
                .one => {
                    try serialize(info.child, val.*, writer);
                },
                .slice => {
                    if (info.sentinel_ptr != null) {
                        @compileError("Sentinel-terminated slices are not supported");
                    }

                    try serialize(u64, @intCast(val.len), writer);
                    for (val) |element| {
                        try serialize(info.child, element, writer);
                    }
                },
                .many, .c => {
                    @compileError("Cannot serialize a pointer without an element count");
                },
            }
        },
        else => {
            @compileLog("{}\n", .{@typeName(T)});
        },
    }
}

pub fn deserialize(T: type, reader: *Reader, alloc: std.mem.Allocator) !T {
    const type_info = @typeInfo(T);
    var res: T = undefined;

    switch (type_info) {
        .int, .bool, .float => {
            try reader.readSliceAll(std.mem.asBytes(&res));
        },
        .array => |info| {
            for (&res) |*element| {
                element.* = try deserialize(info.child, reader, alloc);
            }
        },
        .optional => |info| {
            if (try deserialize(bool, reader, alloc)) {
                res = try deserialize(info.child, reader, alloc);
            } else {
                res = null;
            }
        },
        .@"struct" => {
            if (@hasDecl(T, "deserialize")) {
                return try T.deserialize(reader, alloc);
            }

            inline for (std.meta.fields(T)) |field| {
                @field(res, field.name) = try deserialize(field.type, reader, alloc);
            }
        },
        .pointer => |info| {
            switch (info.size) {
                .one => {
                    const value = try alloc.create(info.child);
                    errdefer alloc.destroy(value);

                    value.* = try deserialize(info.child, reader, alloc);
                    res = value;
                },
                .slice => {
                    if (info.sentinel_ptr != null) {
                        @compileError("Sentinel-terminated slices are not supported");
                    }

                    const encoded_len = try deserialize(u64, reader, alloc);
                    const len = std.math.cast(usize, encoded_len) orelse return error.InvalidLength;
                    const elements = try alloc.alloc(info.child, len);
                    errdefer alloc.free(elements);

                    for (elements) |*element| {
                        element.* = try deserialize(info.child, reader, alloc);
                    }
                    res = elements;
                },
                .many, .c => {
                    @compileError("Cannot deserialize a pointer without an element count");
                },
            }
        },
        else => @panic("Unsupported type"),
    }

    return res;
}

const TestSimple = struct {
    a: u32,
    b: f32,
};

test "serializer" {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    var reader = std.Io.Reader.fixed(&buffer);
    const allocator = std.testing.allocator;

    {
        try serialize(u8, 10, &writer);

        const new = try deserialize(u8, &reader, allocator);
        try std.testing.expectEqual(10, new);
    }

    {
        try serialize(f32, 10.10, &writer);

        const new = try deserialize(f32, &reader, allocator);
        try std.testing.expectEqual(10.10, new);
    }

    {
        const expected = TestSimple{ .a = 10, .b = 10.10 };
        try serialize(TestSimple, expected, &writer);

        const new = try deserialize(TestSimple, &reader, allocator);
        try std.testing.expectEqualSlices(u8, std.mem.asBytes(&expected), std.mem.asBytes(&new));
    }

    {
        const expected = try allocator.alloc(u8, 100);
        defer allocator.free(expected);

        for (0..100) |i| {
            expected[i] = @truncate(i);
        }

        try serialize([]u8, expected, &writer);

        const new = try deserialize([]u8, &reader, allocator);
        defer allocator.free(new);
        try std.testing.expectEqualSlices(u8, expected, new);
    }

    {
        var expected = SerializableList(TestSimple){};
        defer expected.deinit(allocator);

        for (0..100) |i| {
            try expected.list.append(allocator, TestSimple{ .a = @intCast(i), .b = @floatFromInt(i) });
        }

        try serialize(SerializableList(TestSimple), expected, &writer);

        var new = try deserialize(SerializableList(TestSimple), &reader, allocator);
        defer new.deinit(allocator);

        try std.testing.expectEqualSlices(TestSimple, expected.list.items, new.list.items);
    }
}
