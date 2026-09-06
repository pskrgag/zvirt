//! x86 ACPI setup

const GuestMemory = @import("../../memory.zig").GuestMemory;
const Vm = @import("../../root.zig").Vm;
const acpi = @import("../../acpi/root.zig");
const std = @import("std");
const builtin = @import("builtin");
const layout = @import("layout.zig");

pub fn setup_tables(vm: *Vm) !void {
    const slice = vm.memory.as_slice(layout.BOOT_ACPI_ADDR, layout.BOOT_ACPI_SIZE).?;
    var bump = std.heap.FixedBufferAllocator.init(slice);
    const allocator = bump.allocator();

    // NOTE: this one must be first one to be allocated, since BOOT_ACPI_ADDR is written to
    // acpi_rsdp_addr.
    //
    // A bit fragile, but works.
    const rsdt_ptr = try allocator.create(acpi.rsdt.AcpiTableRsdp);

    const madt_pa = blk: {
        const madt_size = acpi.madt.AcpiTableMadt.size_with_cpus(vm.vcpus_count);
        const madt_ptr = try allocator.alignedAlloc(u8, .@"16", madt_size);
        const madt: *acpi.madt.AcpiTableMadt = @ptrCast(madt_ptr);

        madt.init(vm.vcpus_count);
        break :blk layout.BOOT_ACPI_ADDR +
            (@intFromPtr(madt) - @intFromPtr(bump.buffer.ptr));
    };

    const xsdt_pa = blk: {
        const xsdt_size = acpi.xsdt.AcpiXstd.size_with_entries(1);
        const xsdt_ptr = try allocator.alignedAlloc(u8, .@"16", xsdt_size);
        const xsdt: *acpi.xsdt.AcpiXstd = @ptrCast(xsdt_ptr);

        xsdt.init(&.{madt_pa});
        break :blk layout.BOOT_ACPI_ADDR +
            (@intFromPtr(xsdt) - @intFromPtr(bump.buffer.ptr));
    };

    rsdt_ptr.* = acpi.rsdt.AcpiTableRsdp.new(0, @truncate(xsdt_pa));
}
