//! Image parsing

const std = @import("std");
const bzimage = @import("bzimage.zig");
const arch = @import("../arch/root.zig");
const GuestMemory = @import("../memory.zig").GuestMemory;
const VmConfig = @import("../root.zig").VmConfig;

pub const Image = struct {
    ep: u64,
    load_address: u64,
};

pub fn parse(
    data: []const u8,
    memory: *GuestMemory,
    config: *const VmConfig,
) !Image {
    return bzimage.parse(data, memory, config) catch {
        try memory.write(arch.layout.DEFAULT_LOAD_ADDRESS, data);

        return .{
            .ep = arch.layout.DEFAULT_LOAD_ADDRESS,
            .load_address = arch.layout.DEFAULT_LOAD_ADDRESS,
        };
    };
}

test {
    _ = @import("bzimage.zig");
}
