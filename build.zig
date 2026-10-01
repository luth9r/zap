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

    const test_step = b.step("test", "Run unit and integration tests");

    const test_groups = [_]struct { name: []const u8, filters: []const []const u8 }{
        .{ .name = "git", .filters = &.{"modules.core.git"} },
        .{ .name = "os", .filters = &.{"modules.core.os"} },
        .{ .name = "directory", .filters = &.{"modules.core.directory"} },
        .{ .name = "modules", .filters = &.{ "modules.core.character", "modules.core.cmd_duration", "modules.languages", "modules.module" } },
        .{ .name = "core_cli_shells", .filters = &.{ "tests.harness", "cli", "utils", "config", "engine", "init" } },
    };

    for (test_groups) |grp| {
        const exe_tests = b.addTest(.{
            .name = grp.name,
            .root_module = exe.root_module,
            .filters = grp.filters,
        });

        const run_exe_tests = b.addRunArtifact(exe_tests);
        run_exe_tests.step.dependOn(b.getInstallStep());
        test_step.dependOn(&run_exe_tests.step);
    }
}
