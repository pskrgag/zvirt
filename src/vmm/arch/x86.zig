//! x86 machine setup policy.

const std = @import("std");
const kvm = @import("kvm");
const GuestMemory = @import("../memory.zig").GuestMemory;
const VmConfig = @import("../root.zig").VmConfig;
const posix = std.posix;
const Allocator = std.mem.Allocator;
const gdt = @import("gdt.zig");
const paging = @import("paging.zig");

const DEFAULT_LOAD_ADDRESS = 0x00100000;

// Long-mode enable
const EFER_LME = 1 << 8;

// Long-mode active
const EFER_LMA = 1 << 10;

// Enable paging
const CR0_PG = 1 << 31;

// Protected mode
const CR0_PE = 1 << 0;

// Enable paging
const CR4_PAE = 1 << 5;

const GDT_ADDR = 0x4000;

pub const io_bus = @import("io_bus.zig");

pub const Config = struct {};

const MemorySlot = struct {
    start: u64,
    length: u64,
    kind: enum {
        Ram,
        Reserved,
    },
};

pub fn setup_vcpu(vcpu: *kvm.Vcpu) !void {
    {
        var sregs = try vcpu.get_sregs();

        // Setup segments. This setups cached version of GDT
        gdt.setup_segment(&sregs.cs, true, gdt.GDT_CODE_INDEX);
        gdt.setup_segment(&sregs.ds, false, gdt.GDT_DATA_INDEX);
        gdt.setup_segment(&sregs.ss, false, gdt.GDT_DATA_INDEX);
        gdt.setup_segment(&sregs.gs, false, gdt.GDT_DATA_INDEX);
        gdt.setup_segment(&sregs.fs, false, gdt.GDT_DATA_INDEX);
        gdt.setup_segment(&sregs.es, false, gdt.GDT_DATA_INDEX);

        // Enable long mode
        sregs.efer = EFER_LME | EFER_LMA;

        // Enable paging
        sregs.cr0 = CR0_PG | CR0_PE;

        // Enable physical address extension
        sregs.cr4 = CR4_PAE;

        // Enable physical address extension
        sregs.cr3 = paging.PGD_ADDR;

        try vcpu.set_sregs(&sregs);
    }

    {
        var sregs = try vcpu.get_sregs2();

        sregs.gdt.base = GDT_ADDR;
        sregs.gdt.limit = 23;

        try vcpu.set_sregs2(&sregs);
    }

    var regs = try vcpu.get_regs();
    regs.rip = DEFAULT_LOAD_ADDRESS;
    try vcpu.set_regs(&regs);
}

pub fn setup_memory(memory: *GuestMemory, config: VmConfig, alloc: Allocator) !void {
    const memory_layout = [_]MemorySlot{
        MemorySlot{ .start = 0x00000000, .length = 0x000A0000, .kind = .Ram },
        MemorySlot{ .start = 0x000A0000, .length = 0x00060000, .kind = .Reserved },
        MemorySlot{ .start = 0x00100000, .length = config.ram_size, .kind = .Ram },
    };

    for (memory_layout) |entry| {
        if (entry.kind == .Ram) {
            const ram = try posix.mmap(
                null,
                entry.length,
                .{ .READ = true, .WRITE = true },
                .{ .ANONYMOUS = true, .TYPE = .PRIVATE },
                -1,
                0,
            );

            try memory.add(entry.start, ram, alloc);
        }
    }

    try memory.write(paging.PGD_ADDR, std.mem.asBytes(&paging.PGD));
    try memory.write(paging.PUD_ADDR, std.mem.asBytes(&paging.PUD));
    try memory.write(paging.PMD_ADDR, std.mem.asBytes(&paging.PMD));

    try memory.write(GDT_ADDR, std.mem.asBytes(&gdt.gdt()));
    try memory.write(DEFAULT_LOAD_ADDRESS, config.binary);
}
