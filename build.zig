const std = @import("std");

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const profile = b.option(bool, "profile", "Preserve frame pointers for perf profiling") orelse false;
    const tsan = b.option(bool, "tsan", "Enable ThreadSanitizer for tests only") orelse false;
    const ci = b.option(bool, "ci", "Use line-oriented CI test reporting") orelse false;
    const test_filters = b.option(
        []const []const u8,
        "test-filter",
        "Run only tests whose names contain any of these strings",
    ) orelse &.{};
    const cli = b.dependency("cli", .{});

    const utils = b.addModule("utils", .{
        .root_source_file = b.path("src/utils/root.zig"),
        .target = target,
    });

    const test_utils = b.addModule("test_utils", .{
        .root_source_file = b.path("src/test_utils/root.zig"),
        .target = target,
    });

    const kvm = b.addModule("kvm", .{
        .root_source_file = b.path("src/kvm/root.zig"),
        .target = target,
        .link_libc = true,
        .imports = &.{
            .{ .name = "test_utils", .module = test_utils },
            .{ .name = "utils", .module = utils },
        },
    });

    const vmm = b.addModule("vmm", .{
        .root_source_file = b.path("src/vmm/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "kvm", .module = kvm },
            .{ .name = "utils", .module = utils },
            .{ .name = "test_utils", .module = test_utils },
        },
    });

    const mod = b.addModule("zvirt", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "vmm", .module = vmm },
        },
    });

    // Here we define an executable. An executable needs to have a root module
    // which needs to expose a `main` function. While we could add a main function
    // to the module defined above, it's sometimes preferable to split business
    // logic and the CLI into two separate modules.
    //
    // If your goal is to create a Zig library for others to use, consider if
    // it might benefit from also exposing a CLI tool. A parser library for a
    // data serialization format could also bundle a CLI syntax checker, for example.
    //
    // If instead your goal is to create an executable, consider if users might
    // be interested in also being able to embed the core functionality of your
    // program in their own executable in order to avoid the overhead involved in
    // subprocessing your CLI tool.
    //
    // If neither case applies to you, feel free to delete the declaration you
    // don't need and to put everything under a single module.
    const exe = b.addExecutable(.{
        .name = "zvirt",
        .root_module = b.createModule(.{
            // b.createModule defines a new module just like b.addModule but,
            // unlike b.addModule, it does not expose the module to consumers of
            // this package, which is why in this case we don't have to give it a name.
            .root_source_file = b.path("src/main.zig"),
            // Target and optimization levels must be explicitly wired in when
            // defining an executable or library (in the root module), and you
            // can also hardcode a specific target for an executable or library
            // definition if desireable (e.g. firmware for embedded devices).
            .target = target,
            .optimize = optimize,
            // List of modules available for import in source files part of the
            // root module.
            .imports = &.{
                // Here "zvirt" is the name you will use in your source code to
                // import this module (e.g. `@import("zvirt")`). The name is
                // repeated because you are allowed to rename your imports, which
                // can be extremely useful in case of collisions (which can happen
                // importing modules from different packages).
                .{ .name = "zvirt", .module = mod },
                .{ .name = "cli", .module = cli.module("cli") },
            },
        }),
    });

    // This declares intent for the executable to be installed into the
    // install prefix when running `zig build` (i.e. when executing the default
    // step). By default the install prefix is `zig-out/` but can be overridden
    // by passing `--prefix` or `-p`.
    if (profile) {
        for ([_]*std.Build.Module{ exe.root_module, mod, vmm, kvm, utils, test_utils, cli.module("cli") }) |module| {
            module.omit_frame_pointer = false;
            module.unwind_tables = .async;
            module.strip = false;
        }
    }

    b.installArtifact(exe);

    // This creates a top level step. Top level steps have a name and can be
    // invoked by name when running `zig build` (e.g. `zig build run`).
    // This will evaluate the `run` step rather than the default step.
    // For a top level step to actually do something, it must depend on other
    // steps (e.g. a Run step, as we will see in a moment).
    const run_step = b.step("run", "Run the app");

    // This creates a RunArtifact step in the build graph. A RunArtifact step
    // invokes an executable compiled by Zig. Steps will only be executed by the
    // runner if invoked directly by the user (in the case of top level steps)
    // or if another step depends on it, so it's up to you to define when and
    // how this Run step will be executed. In our case we want to run it when
    // the user runs `zig build run`, so we create a dependency link.
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    // By making the run step depend on the default step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Keep sanitizer settings separate from the executable's module graph.
    const test_utils_mod = b.createModule(.{
        .root_source_file = b.path("src/utils/root.zig"),
        .target = target,
        .sanitize_thread = tsan,
    });
    const test_helpers_mod = b.createModule(.{
        .root_source_file = b.path("src/test_utils/root.zig"),
        .target = target,
        .sanitize_thread = tsan,
    });
    const test_kvm_mod = b.createModule(.{
        .root_source_file = b.path("src/kvm/root.zig"),
        .target = target,
        .link_libc = true,
        .sanitize_thread = tsan,
        .imports = &.{
            .{ .name = "test_utils", .module = test_helpers_mod },
            .{ .name = "utils", .module = test_utils_mod },
        },
    });
    const test_vmm_mod = b.createModule(.{
        .root_source_file = b.path("src/vmm/root.zig"),
        .target = target,
        .sanitize_thread = tsan,
        .imports = &.{
            .{ .name = "kvm", .module = test_kvm_mod },
            .{ .name = "utils", .module = test_utils_mod },
            .{ .name = "test_utils", .module = test_helpers_mod },
        },
    });
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .sanitize_thread = tsan,
        .imports = &.{.{ .name = "vmm", .module = test_vmm_mod }},
    });
    const test_main_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = tsan,
        .imports = &.{
            .{ .name = "zvirt", .module = test_mod },
            .{ .name = "cli", .module = cli.module("cli") },
        },
    });

    const mod_tests = b.addTest(.{
        .root_module = if (tsan) test_mod else mod,
        .filters = test_filters,
    });

    const util_tests = b.addTest(.{
        .root_module = if (tsan) test_utils_mod else utils,
        .filters = test_filters,
    });

    const test_util_tests = b.addTest(.{
        .root_module = if (tsan) test_helpers_mod else test_utils,
        .filters = test_filters,
    });

    const vmm_tests = b.addTest(.{
        .root_module = if (tsan) test_vmm_mod else vmm,
        .filters = test_filters,
    });

    const run_mod_tests = test_run(b, mod_tests, ci);
    const run_util_tests = test_run(b, util_tests, ci);
    const run_test_util_tests = test_run(b, test_util_tests, ci);
    const run_vmm_tests = test_run(b, vmm_tests, ci);

    // Creates an executable that will run `test` blocks from the executable's
    // root module. Note that test executables only test one module at a time,
    // hence why we have to create two separate ones.
    const exe_tests = b.addTest(.{
        .root_module = if (tsan) test_main_mod else exe.root_module,
        .filters = test_filters,
    });

    // A run step that will run the second test executable.
    const run_exe_tests = test_run(b, exe_tests, ci);

    if (ci) {
        run_test_util_tests.step.dependOn(&run_util_tests.step);
        run_vmm_tests.step.dependOn(&run_test_util_tests.step);
        run_mod_tests.step.dependOn(&run_vmm_tests.step);
        run_exe_tests.step.dependOn(&run_mod_tests.step);
    }

    if (tsan) {
        for ([_]*std.Build.Step.Compile{ mod_tests, util_tests, test_util_tests, vmm_tests, exe_tests }) |tests| {
            tests.use_llvm = true;
        }
    }

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_util_tests.step);
    test_step.dependOn(&run_test_util_tests.step);
    test_step.dependOn(&run_vmm_tests.step);
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // Just like flags, top level steps are also listed in the `--help` menu.
    //
    // The Zig build system is entirely implemented in userland, which means
    // that it cannot hook into private compiler APIs. All compilation work
    // orchestrated by the build system will result in other Zig compiler
    // subcommands being invoked with the right flags defined. You can observe
    // these invocations when one fails (or you pass a flag to increase
    // verbosity) to validate assumptions and diagnose problems.
    //
    // Lastly, the Zig build system is relatively simple and self-contained,
    // and reading its source code will allow you to master it.
}

fn test_run(b: *std.Build, tests: *std.Build.Step.Compile, ci: bool) *std.Build.Step.Run {
    if (ci) {
        tests.test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple };
    }

    const run = b.addRunArtifact(tests);
    if (ci) {
        run.stdio = .inherit;
    }
    return run;
}
