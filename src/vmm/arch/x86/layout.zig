//! Guest physical-address layout used during x86 boot.

const VmConfig = @import("../../root.zig").VmConfig;

pub const PGD_ADDR = 0x1000;
pub const PUD_ADDR = 0x2000;
pub const PMD_ADDR = 0x3000;
pub const GDT_ADDR = 0x4000;
pub const BOOT_PARAM_ADDR = 0x5000;
pub const BOOT_CMDLINE_ADDR = 0x6000;
pub const DEFAULT_LOAD_ADDRESS = 0x100000;

const E820_RAM = 1;
const E820_RESERVED = 2;

pub const LOW_RAM_BEGIN = 0x0;
pub const HIGH_RAM_BEGIN = 0x00100000;

pub const MemorySlot = struct {
    start: u64,
    length: u64,
    kind: enum(u32) {
        Ram = E820_RAM,
        Reserved = E820_RESERVED,
    },
};

pub fn memory_layout(config: *const VmConfig) [3]MemorySlot {
    return [3]MemorySlot{
        MemorySlot{ .start = LOW_RAM_BEGIN, .length = 0x000A0000, .kind = .Ram },
        MemorySlot{ .start = 0x000A0000, .length = 0x00060000, .kind = .Reserved },
        MemorySlot{ .start = HIGH_RAM_BEGIN, .length = config.ram_size, .kind = .Ram },
    };
}
