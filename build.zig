const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const exe = b.addExecutable(.{
        .name = "mpd-discord-presence",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);

    // Check Step (no emit bin)
    const exe_check = b.addExecutable(.{
        .name = "mpd_discord_rpc",
        .root_module = exe_mod,
    });

    const check_exe = b.step("check", "Build on save check (no emit bin)");
    check_exe.dependOn(&exe_check.step);

    const exe_bc = b.addInstallFile(exe_check.getEmittedLlvmBc(), "llvm/llvm.bc");
    const exe_bc_step = b.step("llvm-bc", "Emit LLVM BC of entire exe");
    exe_bc_step.dependOn(&exe_bc.step);
}
