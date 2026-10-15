//! Arch vCPU state

const kvm = @import("kvm");

pub const ArchVcpuState = extern struct {
    mp: kvm.vcpu.MpState,
    regs: kvm.vcpu.Regs,
    sregs: kvm.vcpu.Sregs,
    sregs2: kvm.vcpu.Sregs2,
    events: kvm.vcpu.VCpuEvents,
    lapic: kvm.vcpu.LapicState,
    msrs: kvm.vcpu.MsrState,
    xsave: kvm.vcpu.XsaveState,
    xcrs: kvm.vcpu.Xcrs,
    tsc_khz: u32,
};

const MsrStage = enum { model, before_lapic, after_lapic };

fn msr_stage(index: u32) MsrStage {
    return switch (index) {
        // FEATURE_CONTROL, VMX capabilities, and MSR-based CPU features.
        0x3a, 0x8b, 0xce, 0x10a, 0x345, 0x480...0x4ff => .model,
        // IA32_TSC_DEADLINE: LAPIC restore clears it, and TSC must be set first.
        0x6e0 => .after_lapic,
        else => .before_lapic,
    };
}

fn restore_msrs(cpu: *const kvm.vcpu.Vcpu, msrs: *const kvm.vcpu.MsrState, stage: MsrStage) !void {
    if (msrs.nmsrs > msrs.entries.len) {
        return error.InvalidMsrCount;
    }

    var batch = kvm.vcpu.MsrState{};

    for (msrs.entries[0..msrs.nmsrs]) |entry| {
        if (msr_stage(entry.index) == stage) {
            batch.entries[batch.nmsrs] = entry;
            batch.nmsrs += 1;
        }
    }

    try cpu.set_msrs(batch.entries[0..batch.nmsrs]);
}

pub fn snapshot_cpu(cpu: *const kvm.vcpu.Vcpu) !ArchVcpuState {
    // https://lwn.net/Articles/1094324/
    const mp = try cpu.get_mp_state();
    const events = try cpu.get_vcpu_events();
    const regs = try cpu.get_regs();
    const sregs = try cpu.get_sregs();
    const sregs2 = try cpu.get_sregs2();
    const xcrs = try cpu.get_xcrs();
    const xsave = try cpu.get_xsave();
    // Keep MSRs before LAPIC for older kernels' TSC-deadline behavior.
    const msrs = try cpu.get_msrs();
    const tsc_khz = try cpu.get_tsc_khz();

    // LAPIC must be the last vCPU getter to collect posted interrupts.
    const lapic = try cpu.get_lapic();

    return .{
        .regs = regs,
        .sregs = sregs,
        .sregs2 = sregs2,
        .events = events,
        .lapic = lapic,
        .mp = mp,
        .msrs = msrs,
        .xsave = xsave,
        .xcrs = xcrs,
        .tsc_khz = tsc_khz,
    };
}

pub fn restore_cpu(cpu: *kvm.vcpu.Vcpu, state: *const ArchVcpuState) !void {
    try restore_msrs(cpu, &state.msrs, .model);

    try cpu.set_tsc_khz(state.tsc_khz);
    try cpu.set_regs(&state.regs);
    try cpu.set_sregs(&state.sregs);
    try cpu.set_sregs2(&state.sregs2);
    try cpu.set_xcrs(&state.xcrs);
    // XSAVE must precede IA32_XFD, which can disable saved state components.
    try cpu.set_xsave(&state.xsave);
    try restore_msrs(cpu, &state.msrs, .before_lapic);

    try cpu.set_lapic(&state.lapic);
    try restore_msrs(cpu, &state.msrs, .after_lapic);
    try cpu.set_vcpu_events(&state.events);

    try cpu.set_mp_state(&state.mp);
}
