//! Virtio block device

const VIRTIO_BLK_F_RO: u32 = 1 << 5;

pub const Block = struct {
    pub const TYPE = 0x2;

    const Self = @This();

    pub fn features() u32 {
        return VIRTIO_BLK_F_RO;
    }

    pub fn read_config(self: *Self, offset: u32) u32 {
        _ = self;
        _ = offset;

        @panic("todo");
    }
};
