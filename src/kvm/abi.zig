//! Linux KVM C API declarations shared by the raw wrappers.

pub const c = @cImport({
    @cInclude("linux/kvm.h");
});
