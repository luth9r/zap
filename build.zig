const std = @import("std");
const build_zon = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const options = b.addOptions();
    options.addOption([]const u8, "version", build_zon.version);

    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    root_mod.addOptions("build_options", options);

    const exe = b.addExecutable(.{
        .name = "zap",
        .root_module = root_mod,
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run zap");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    const test_step = b.step("test", "Run unit and integration tests (parallel)");

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
        .test_runner = .{ .path = b.path("src/tests/runner.zig"), .mode = .simple },
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);
    run_exe_tests.setCwd(b.path("."));
    if (b.args) |args| run_exe_tests.addArgs(args);
    run_exe_tests.step.dependOn(b.getInstallStep());
    test_step.dependOn(&run_exe_tests.step);

    const test_unit_step = b.step("test-unit", "Run unit tests only");
    const run_unit_tests = b.addRunArtifact(exe_tests);
    run_unit_tests.addArg("--unit-only");
    if (b.args) |args| run_unit_tests.addArgs(args);
    run_unit_tests.setCwd(b.path("."));
    test_unit_step.dependOn(&run_unit_tests.step);

    const test_int_step = b.step("test-integration", "Run integration tests only");
    const run_int_tests = b.addRunArtifact(exe_tests);
    run_int_tests.addArg("--integration-only");
    if (b.args) |args| run_int_tests.addArgs(args);
    run_int_tests.setCwd(b.path("."));
    run_int_tests.step.dependOn(b.getInstallStep());
    test_int_step.dependOn(&run_int_tests.step);
}
