const std = @import("std");
const registry = @import("../../../modules/registry.zig");
const context = @import("../../../engine/context.zig");
const BufferWriter = @import("../../../utils/buffer_writer.zig").BufferWriter;

pub const git_reporter = @import("git_reporter.zig");
pub const config_reporter = @import("config_reporter.zig");
pub const env_reporter = @import("env_reporter.zig");
pub const bench_reporter = @import("bench_reporter.zig");

const PromptContext = context.PromptContext;
const DebugContext = context.DebugContext;

pub const Args = struct {
    module_name: ?[]const u8 = null,
    json: bool = false,
    verbose: bool = false,
    output_path: ?[]const u8 = null,
};

pub const DebugTarget = enum {
    git,
    config,
    bench,
    profile,
    prompt,
    env,
    shell,
    all,
};

pub fn execute(init: std.process.Init, args: Args) !void {
    var buf: [65536]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = context.resolveCwdPath(init, &cwd_buf);
    const home = context.resolveHomePath(init);

    const prompt_ctx = PromptContext{
        .cwd = cwd,
        .home = home,
        .io = init.io,
    };

    const dctx = DebugContext{
        .prompt = prompt_ctx,
        .json = args.json,
        .verbose = args.verbose,
    };

    const target_str = args.module_name orelse "all";
    const target_enum_opt = std.meta.stringToEnum(DebugTarget, target_str);

    if (target_enum_opt) |target_enum| {
        switch (target_enum) {
            .git => {
                if (dctx.verbose) {
                    try git_reporter.printGitVerboseDebug(init, writer, dctx);
                } else {
                    inline for (@typeInfo(registry).@"struct".decls) |decl| {
                        const mod = @field(registry, decl.name);
                        if (std.mem.startsWith(u8, decl.name, "git_")) {
                            if (@hasDecl(mod, "debug")) {
                                try mod.debug(writer, dctx);
                            }
                        }
                    }
                }
            },
            .config => try config_reporter.printConfigDebug(init, writer, dctx),
            .bench, .profile, .prompt => try bench_reporter.printPromptProfileDebug(init, writer, dctx),
            .env, .shell => try env_reporter.printEnvDebug(init, writer, dctx),
            .all => {
                inline for (@typeInfo(registry).@"struct".decls) |decl| {
                    const mod = @field(registry, decl.name);
                    if (@hasDecl(mod, "debug")) {
                        try mod.debug(writer, dctx);
                    }
                }
            },
        }
    } else {
        var found = false;
        inline for (@typeInfo(registry).@"struct".decls) |decl| {
            const mod = @field(registry, decl.name);
            if (std.mem.eql(u8, target_str, decl.name)) {
                if (@hasDecl(mod, "debug")) {
                    found = true;
                    try mod.debug(writer, dctx);
                }
            }
        }

        if (!found) {
            var err_buf: [256]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "✖ Error: module '{s}' not found or does not support debug.\n", .{target_str}) catch "Error: unknown debug module.\n";
            _ = std.Io.File.stderr().writeStreamingAll(init.io, err_msg) catch {};
            std.process.exit(1);
        }
    }

    if (args.output_path) |out_path| {
        var file = if (std.fs.path.isAbsolute(out_path))
            try std.Io.Dir.createFileAbsolute(init.io, out_path, .{})
        else
            try std.Io.Dir.cwd().createFile(init.io, out_path, .{});
        defer file.close(init.io);
        try file.writeStreamingAll(init.io, buf[0..pos]);
    } else {
        try std.Io.File.stdout().writeStreamingAll(init.io, buf[0..pos]);
    }
}

const testing = std.testing;
const Harness = @import("../../../tests/harness.zig").Harness;

test "integration: zap debug git in repository" {
    var h = try Harness.create(testing.allocator);
    defer h.destroy();

    try h.setupGit();
    try h.writeFile("test.txt", "hello");
    try h.git(&.{ "add", "test.txt" });
    try h.git(&.{ "commit", "-m", "initial commit" });
    try h.writeFile("test.txt", "modified content");

    const out = try h.execZap(&.{ "debug", "git" });
    try Harness.expectContains(out, "Module: git_branch");
    try Harness.expectContains(out, "Module: git_status");
    try Harness.expectContains(out, "Modified (!):   true");
}

test "integration: zap debug git with --json" {
    var h = try Harness.create(testing.allocator);
    defer h.destroy();

    try h.setupGit();
    const out = try h.execZap(&.{ "debug", "git", "--json" });
    try Harness.expectContains(out, "\"module\": \"git_branch\"");
    try Harness.expectContains(out, "\"module\": \"git_status\"");
}

test "integration: zap debug language module zig_lang" {
    var h = try Harness.create(testing.allocator);
    defer h.destroy();

    try h.writeFile("build.zig", "const std = @import(\"std\");\n");
    const out = try h.execZap(&.{ "debug", "zig_lang" });
    try Harness.expectContains(out, "Module: zig_lang");
    try Harness.expectContains(out, "Detected:   true");
}

test "integration: zap debug unknown module produces error and exit 1" {
    var h = try Harness.create(testing.allocator);
    defer h.destroy();

    const res = try h.execZapAllowFail(&.{ "debug", "nonexistent_module_xyz" });
    try testing.expectEqual(@as(u8, 1), res.exit_code);
    try Harness.expectContains(res.stderr, "module 'nonexistent_module_xyz' not found");
}

test "integration: zap debug config" {
    var h = try Harness.create(testing.allocator);
    defer h.destroy();

    try h.writeFile(".config/zap/zap.toml", "add_newline = false\nformat = \"$directory$character\"\n");
    const out = try h.execZap(&.{ "debug", "config" });

    try Harness.expectContains(out, "Zap Config Inspector");
    try Harness.expectContains(out, "Active Modules:");
    try Harness.expectContains(out, "✔ directory");
    try Harness.expectContains(out, "✔ character");
    try Harness.expectContains(out, "· git_branch");
}

test "integration: zap debug config with --json" {
    var h = try Harness.create(testing.allocator);
    defer h.destroy();

    try h.writeFile(".config/zap/zap.toml", "add_newline = false\nformat = \"$directory$character\"\n");
    const out = try h.execZap(&.{ "debug", "config", "--json" });

    try Harness.expectContains(out, "\"active_modules\": [");
    try Harness.expectContains(out, "\"directory\"");
    try Harness.expectContains(out, "\"character\"");
    try Harness.expectContains(out, "\"inactive_modules\": [");
}

test "integration: zap debug writes to file with -o flag" {
    var h = try Harness.create(testing.allocator);
    defer h.destroy();

    try h.setupGit();
    _ = try h.execZap(&.{ "debug", "git", "--json", "-o", "report.json" });

    const full_path = try std.fmt.allocPrint(h.arena.allocator(), "{s}/report.json", .{h.tmp_dir});
    var read_buf: [4096]u8 = undefined;
    const file_content = @import("../../../utils/fs.zig").readSmallFile(std.testing.io, full_path, &read_buf) orelse "";

    try Harness.expectContains(file_content, "\"module\": \"git_branch\"");
    try Harness.expectContains(file_content, "\"module\": \"git_status\"");
}

test "integration: zap debug git in verbose mode" {
    var h = try Harness.create(testing.allocator);
    defer h.destroy();

    try h.setupGit();
    try h.writeFile("file.txt", "hello");
    try h.git(&.{ "add", "file.txt" });
    try h.git(&.{ "commit", "-m", "init" });
    try h.writeFile("file.txt", "changed content");
    try h.writeFile("new_untracked.txt", "untracked");

    const out = try h.execZap(&.{ "debug", "git", "--verbose" });
    try Harness.expectContains(out, "Zap Git Diagnostic Inspector (Verbose Mode)");
    try Harness.expectContains(out, "Index Entries:");
    try Harness.expectContains(out, "tracked files");
    try Harness.expectContains(out, "Modified Files (!):");
    try Harness.expectContains(out, "file.txt");
    try Harness.expectContains(out, "Untracked Files (?):");
    try Harness.expectContains(out, "new_untracked.txt");
    try Harness.expectContains(out, "Scan Duration:");
}

test "integration: zap debug git in verbose mode with --json" {
    var h = try Harness.create(testing.allocator);
    defer h.destroy();

    try h.setupGit();
    try h.writeFile("modified_test.txt", "initial");
    try h.git(&.{ "add", "modified_test.txt" });
    try h.git(&.{ "commit", "-m", "commit 1" });
    try h.writeFile("modified_test.txt", "modified");
    try h.writeFile("some_untracked.txt", "untracked");

    const out = try h.execZap(&.{ "debug", "git", "-v", "--json" });
    try Harness.expectContains(out, "\"verbose\": true");
    try Harness.expectContains(out, "\"index_entries\":");
    try Harness.expectContains(out, "\"files\":");
    try Harness.expectContains(out, "\"modified\": [\"modified_test.txt\"]");
    try Harness.expectContains(out, "\"untracked\": [\"some_untracked.txt\"]");
    try Harness.expectContains(out, "\"scan_duration_us\":");
}

test "integration: zap debug bench profiler" {
    var h = try Harness.create(testing.allocator);
    defer h.destroy();

    try h.setupGit();
    const out = try h.execZap(&.{ "debug", "bench" });
    try Harness.expectContains(out, "Zap Prompt Engine Profiler & Benchmark");
    try Harness.expectContains(out, "Per-Module Execution Breakdown");
    try Harness.expectContains(out, "directory");
    try Harness.expectContains(out, "git_branch");
    try Harness.expectContains(out, "Pipeline Stages:");
    try Harness.expectContains(out, "Multi-Pass Benchmark");
    try Harness.expectContains(out, "Throughput:");
}

test "integration: zap debug bench with --json" {
    var h = try Harness.create(testing.allocator);
    defer h.destroy();

    try h.setupGit();
    const out = try h.execZap(&.{ "debug", "bench", "--json" });
    try Harness.expectContains(out, "\"target\": \"prompt_profiler\"");
    try Harness.expectContains(out, "\"total_render_us\":");
    try Harness.expectContains(out, "\"modules\": [");
    try Harness.expectContains(out, "\"benchmark\":");
    try Harness.expectContains(out, "\"iterations\": 100");
    try Harness.expectContains(out, "\"throughput_renders_per_sec\":");
}

test "integration: zap debug language module in verbose mode" {
    var h = try Harness.create(testing.allocator);
    defer h.destroy();

    try h.writeFile("build.zig", "const std = @import(\"std\");\n");
    const out = try h.execZap(&.{ "debug", "zig_lang", "-v" });
    try Harness.expectContains(out, "Module: zig_lang");
    try Harness.expectContains(out, "Detected:   true");
    try Harness.expectContains(out, "Matched:    build.zig");
    try Harness.expectContains(out, "depth: 0");
}

test "integration: zap debug language module in verbose mode with --json" {
    var h = try Harness.create(testing.allocator);
    defer h.destroy();

    try h.writeFile("build.zig", "const std = @import(\"std\");\n");
    const out = try h.execZap(&.{ "debug", "zig_lang", "-v", "--json" });
    try Harness.expectContains(out, "\"module\": \"zig_lang\"");
    try Harness.expectContains(out, "\"detected\": true");
    try Harness.expectContains(out, "\"verbose\": true");
    try Harness.expectContains(out, "\"matched\": \"build.zig\"");
}

test "integration: zap debug config in verbose mode" {
    var h = try Harness.create(testing.allocator);
    defer h.destroy();

    try h.writeFile(".config/zap/zap.toml", "add_newline = false\nformat = \"$directory$character\"\n");
    const out = try h.execZap(&.{ "debug", "config", "-v" });
    try Harness.expectContains(out, "Zap Config Inspector (Verbose Mode)");
    try Harness.expectContains(out, "Module Configurations (Verbose):");
    try Harness.expectContains(out, "[directory]");
    try Harness.expectContains(out, "[git_branch]");
}

test "integration: zap debug config in verbose mode with --json" {
    var h = try Harness.create(testing.allocator);
    defer h.destroy();

    try h.writeFile(".config/zap/zap.toml", "add_newline = false\nformat = \"$directory$character\"\n");
    const out = try h.execZap(&.{ "debug", "config", "-v", "--json" });
    try Harness.expectContains(out, "\"verbose\": true");
    try Harness.expectContains(out, "\"modules\": {");
    try Harness.expectContains(out, "\"directory\": {");
    try Harness.expectContains(out, "\"git_branch\": {");
}

test "integration: zap debug env" {
    var h = try Harness.create(testing.allocator);
    defer h.destroy();

    const out = try h.execZap(&.{ "debug", "env" });
    try Harness.expectContains(out, "Zap Environment & Terminal Inspector");
    try Harness.expectContains(out, "Detected Shell:");
    try Harness.expectContains(out, "Terminal ($TERM):");
    try Harness.expectContains(out, "Color Support:");
    try Harness.expectContains(out, "Shell Integration Hooks:");
}

test "integration: zap debug env with --json" {
    var h = try Harness.create(testing.allocator);
    defer h.destroy();

    const out = try h.execZap(&.{ "debug", "env", "--json" });
    try Harness.expectContains(out, "\"target\": \"env\"");
    try Harness.expectContains(out, "\"color_support\":");
    try Harness.expectContains(out, "\"variables\":");
    try Harness.expectContains(out, "\"hooks\":");
}

test "integration: zap debug defaults to all modules" {
    var h = try Harness.create(testing.allocator);
    defer h.destroy();

    try h.setupGit();
    const out = try h.execZap(&.{"debug"});
    try Harness.expectContains(out, "Module: directory");
    try Harness.expectContains(out, "Module: git_branch");
    try Harness.expectContains(out, "Module: git_status");
    try Harness.expectContains(out, "Module: character");
    try Harness.expectContains(out, "Module: cmd_duration");
    try Harness.expectContains(out, "Module: os");
    try Harness.expectContains(out, "Module: zig_lang");
}

test "integration: zap debug os, character, cmd_duration" {
    var h = try Harness.create(testing.allocator);
    defer h.destroy();

    const out_os = try h.execZap(&.{ "debug", "os" });
    try Harness.expectContains(out_os, "Module: os");
    try Harness.expectContains(out_os, "Detected OS:");

    const out_char = try h.execZap(&.{ "debug", "character" });
    try Harness.expectContains(out_char, "Module: character");
    try Harness.expectContains(out_char, "Status Code:");

    const out_dur = try h.execZap(&.{ "debug", "cmd_duration" });
    try Harness.expectContains(out_dur, "Module: cmd_duration");
    try Harness.expectContains(out_dur, "Duration (ms):");
}

