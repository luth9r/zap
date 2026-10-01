const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zap",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run zap");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    const test_step = b.step("test", "Run unit and integration tests");

    const test_groups = [_][]const []const u8{
        &.{"modules.git"},
        &.{"modules.os"},
        &.{"modules.directory"},
        &.{ "modules.character", "modules.cmd_duration" },
        &.{ "tests.harness", "utils", "config", "engine", "init" },
    };

    for (test_groups, 0..) |filters, i| {
        const group_name = b.fmt("test_{d}", .{i});
        const exe_tests = b.addTest(.{
            .name = group_name,
            .root_module = exe.root_module,
            .filters = filters,
        });

        const run_exe_tests = b.addRunArtifact(exe_tests);
        run_exe_tests.step.dependOn(b.getInstallStep());
        test_step.dependOn(&run_exe_tests.step);
    }
}
