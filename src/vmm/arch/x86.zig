//! x86 machine setup policy.

const kvm = @import("kvm");

pub const io_bus = @import("io_bus.zig");

pub fn setup_vcpu(vcpu: *kvm.Vcpu) !void {
    var sregs = try vcpu.get_sregs();
    sregs.cs.base = 0;
    sregs.cs.selector = 0;
    try vcpu.set_sregs(&sregs);

    var regs = try vcpu.get_regs();
    regs.rip = 0x1000;
    try vcpu.set_regs(&regs);
}
