//! Architecture-specific VMM interface.

const builtin = @import("builtin");

const implementation = switch (builtin.cpu.arch) {
    .x86, .x86_64 => @import("x86/vm.zig"),
    else => @compileError("unsupported architecture"),
};

pub const ArchVm = implementation.ArchVm;
pub const layout = implementation.layout;
pub const setup_bs_vcpu = implementation.setup_bs_vcpu;
