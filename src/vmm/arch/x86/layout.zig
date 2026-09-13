//! Guest physical-address layout used during x86 boot.

const VmConfig = @import("../../root.zig").VmConfig;
const std = @import("std");

pub const PGD_ADDR = 0x1000;
pub const PUD_ADDR = 0x2000;
pub const PMD_ADDR = 0x3000;
pub const GDT_ADDR = 0x4000;
pub const BOOT_PARAM_ADDR = 0x5000;
pub const BOOT_CMDLINE_ADDR = 0x6000;
pub const BOOT_ACPI_ADDR = 0x9e000;
pub const BOOT_ACPI_SIZE = 0x2000;
pub const DEFAULT_LOAD_ADDRESS = 0x100000;

const E820_RAM = 1;
const E820_RESERVED = 2;
const E820_ACPI = 3;

pub const LOW_RAM_BEGIN = 0x0;
pub const HIGH_RAM_BEGIN = 0x00100000;

pub const MemorySlot = struct {
    start: u64,
    length: u64,
    kind: enum(u32) {
        Ram = E820_RAM,
        Reserved = E820_RESERVED,
        Acpi = E820_ACPI,
    },
};

pub fn virtio_device(config: *const VmConfig, idx: u64) u64 {
    const ram_end = std.mem.alignForward(u64, HIGH_RAM_BEGIN + config.ram_size, 4096);

    return ram_end + idx * 4096;
}

// NOTE: linux reserves first 64k of RAM for allocations:
//
// memblock_reserve(0, SZ_64K);
//
// This memory may be used for AP cpu bootstrap, which has a limit of 1MiB
// TODO: figure out why
pub fn memory_layout(config: *const VmConfig) [5]MemorySlot {
    return [_]MemorySlot{
        MemorySlot{ .start = LOW_RAM_BEGIN, .length = 0x9e000, .kind = .Ram },
        MemorySlot{ .start = BOOT_ACPI_ADDR, .length = 0x2000, .kind = .Acpi },
        MemorySlot{ .start = 0x000A0000, .length = 0x00060000, .kind = .Reserved },
        MemorySlot{ .start = HIGH_RAM_BEGIN, .length = config.ram_size, .kind = .Ram },
        MemorySlot{ .start = HIGH_RAM_BEGIN + config.ram_size, .length = 0x5000, .kind = .Reserved },
    };
}

pub fn pci_range(config: *const VmConfig) MemorySlot {
    const layout = memory_layout(config);

    return layout[layout.len - 1];
}
