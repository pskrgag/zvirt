//! Paging helpers

// For simplicity we map 1GiB. Assuming PDPE1GB is not present

const layout = @import("layout.zig");

pub const PGD = blk: {
    var page: [512]u64 = @splat(0);

    page[0] = layout.PUD_ADDR | (1 << 0) | (1 << 1);
    break :blk page;
};

pub const PUD = blk: {
    var page: [512]u64 = @splat(0);

    page[0] = layout.PMD_ADDR | (1 << 0) | (1 << 1);
    break :blk page;
};

pub const PMD = blk: {
    var page: [512]u64 = @splat(0);

    for (&page, 0..) |*entry, index| {
        entry.* = (@as(u64, index) << 21) |
            (1 << 0) |
            (1 << 1) |
            (1 << 7);
    }
    break :blk page;
};
