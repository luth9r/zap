const std = @import("std");
const testing = std.testing;
const config_mod = @import("../config/config.zig");
const formatter = @import("formatter.zig");
const module_interface = @import("../modules/module.zig");
const BufferWriter = @import("../utils/buffer_writer.zig").BufferWriter;
pub const PromptContext = @import("context.zig").PromptContext;
pub const modules = @import("../modules/registry.zig");
pub const ModuleVar = std.meta.DeclEnum(modules);

comptime {
    const decls = @typeInfo(modules).@"struct".decls;
    for (decls) |decl| {
        const mod = @field(modules, decl.name);
        module_interface.validateModule(mod);
    }
}

/// Computes a bitmask of active modules in a single pass over the format string.
pub fn computeActiveModulesMask(format: []const u8) u16 {
    const decls = @typeInfo(modules).@"struct".decls;
    var mask: u16 = 0;
    var i: usize = 0;
    while (i < format.len) {
        if (format[i] == '\\' and i + 1 < format.len) {
            i += 2;
            continue;
        }
        if (format[i] == '$') {
            const rest = format[i + 1 ..];
            inline for (decls, 0..) |decl, idx| {
                if (std.mem.startsWith(u8, rest, decl.name)) {
                    const end = decl.name.len;
                    if (rest.len == end or (!std.ascii.isAlphanumeric(rest[end]) and rest[end] != '_')) {
                        mask |= @as(u16, 1) << @as(u4, @intCast(idx));
                    }
                }
            }
        }
        i += 1;
    }
    return mask;
}

/// Orchestrates rendering the complete prompt across all active modules using comptime reflection.
pub fn render(writer: anytype, config: config_mod.Config, ctx: PromptContext) !void {
    if (config.add_newline) {
        try writer.writeByte('\n');
    }

    const active_mask = computeActiveModulesMask(config.format);
    const decls = @typeInfo(modules).@"struct".decls;
    var vars: [decls.len]formatter.Variable(ModuleVar) = undefined;

    // Fast Git repo resolution: if any git-dependent module is active and git_dir is not yet supplied,
    // discover it once on the stack frame and pass it down.
    const git_modules_mask = comptime blk: {
        const d = @typeInfo(modules).@"struct".decls;
        var m: u16 = 0;
        for (d, 0..) |decl, idx| {
            const m_mod = @field(modules, decl.name);
            if (@hasDecl(m_mod, "is_git_dependent") and m_mod.is_git_dependent) {
                m |= @as(u16, 1) << @as(u4, @intCast(idx));
            }
        }
        break :blk m;
    };
    const dir_needs_git = config.directory.truncate_to_repo and (active_mask & computeActiveModulesMask("$directory")) != 0;
    const should_check_git = ((active_mask & git_modules_mask) != 0 or dir_needs_git) and ctx.git_dir == null and ctx.io != null;

    var git_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    var resolved_ctx = ctx;
    if (should_check_git) {
        const git_utils = @import("../utils/git_utils.zig");
        resolved_ctx.git_dir = git_utils.findGitDir(resolved_ctx.io.?, resolved_ctx.cwd, &git_dir_buf);
    }

    inline for (decls, 0..) |decl, i| {
        const mod = @field(modules, decl.name);
        const buf_size = if (@hasDecl(mod, "buffer_size")) mod.buffer_size else 512;
        var buf: [buf_size]u8 = undefined;
        var pos: usize = 0;

        const is_active = (active_mask & (@as(u16, 1) << @as(u4, @intCast(i)))) != 0;
        if (is_active) {
            // Fast exit: if this is a purely git-based module and we know we're not in a git repo, skip it
            const is_git_mod = (git_modules_mask & (@as(u16, 1) << @as(u4, @intCast(i)))) != 0;
            if (!is_git_mod or resolved_ctx.git_dir != null) {
                const mod_writer = BufferWriter.init(&buf, &pos);
                const mod_cfg = @field(config, decl.name);
                try mod.render(mod_writer, mod_cfg, resolved_ctx);
            }
        }

        vars[i] = .{
            .name = @field(ModuleVar, decl.name),
            .value = buf[0..pos],
        };
    }

    try formatter.formatTemplateWriter(writer, config.format, formatter.FormatContext(ModuleVar){
        .vars = &vars,
        .shell = ctx.shell,
    });
}

test "unit: render prompt with default configuration" {
    var buf: [1024]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);
    var cfg: config_mod.Config = config_mod.defaultConfig();
    cfg.add_newline = false; // Disable leading newline for exact prefix test
    const ctx = PromptContext{
        .cwd = "/home/user/projects/zap",
        .home = "/home/user",
        .status_code = 0,
    };

    try render(writer, cfg, ctx);

    const expected = "\x1b[1;36m~/projects/zap\x1b[0m \x1b[1;32m❯\x1b[0m ";
    try testing.expectEqualStrings(expected, buf[0..pos]);
}

test "unit: render prompt with error status and custom symbols" {
    var buf: [1024]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);
    var cfg: config_mod.Config = config_mod.defaultConfig();
    cfg.character.error_symbol = "[✗](bold red)";

    const ctx = PromptContext{
        .cwd = "/home/user",
        .home = "/home/user",
        .status_code = 1,
    };

    try render(writer, cfg, ctx);

    const expected = "\n\x1b[1;36m~\x1b[0m \x1b[1;31m✗\x1b[0m ";
    try testing.expectEqualStrings(expected, buf[0..pos]);
}

test "unit: render prompt with disabled module" {
    var buf: [1024]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);
    var cfg: config_mod.Config = config_mod.defaultConfig();
    cfg.add_newline = false;
    cfg.directory.disabled = true;

    const ctx = PromptContext{
        .cwd = "/home/user/zap",
        .home = "/home/user",
        .status_code = 0,
    };

    try render(writer, cfg, ctx);

    const expected = "\x1b[1;32m❯\x1b[0m ";
    try testing.expectEqualStrings(expected, buf[0..pos]);
}

test "unit: render prompt with custom root format" {
    var buf: [1024]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);
    var cfg: config_mod.Config = config_mod.defaultConfig();
    cfg.add_newline = false;
    cfg.format = "in $directory\n$character";
    cfg.directory.style = "cyan";
    cfg.character.success_symbol = "[➜](bold green)";

    const ctx = PromptContext{
        .cwd = "/home/user/zap",
        .home = "/home/user",
        .status_code = 0,
    };

    try render(writer, cfg, ctx);

    const expected = "in \x1b[36m~/zap\x1b[0m \n\x1b[1;32m➜\x1b[0m ";
    try testing.expectEqualStrings(expected, buf[0..pos]);
}

test "unit: render multiline prompt with colored frame symbols" {
    var buf: [1024]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);
    var cfg: config_mod.Config = config_mod.defaultConfig();
    cfg.add_newline = false;
    cfg.format = "[┌─](bold yellow) $directory\n[└─](bold yellow)$character";
    cfg.directory.style = "bold cyan";
    cfg.character.success_symbol = "[❯](bold green)";

    const ctx = PromptContext{
        .cwd = "/home/user/projects/zap",
        .home = "/home/user",
        .status_code = 0,
    };

    try render(writer, cfg, ctx);

    const expected = "\x1b[1;33m┌─\x1b[0m \x1b[1;36m~/projects/zap\x1b[0m \n\x1b[1;33m└─\x1b[0m\x1b[1;32m❯\x1b[0m ";
    try testing.expectEqualStrings(expected, buf[0..pos]);
}

test "unit: render prompt with cmd_duration module" {
    var buf: [1024]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);
    var cfg: config_mod.Config = config_mod.defaultConfig();
    cfg.add_newline = false;
    cfg.format = "$directory$cmd_duration$character";

    // Case 1: duration exceeds default min_time (2000ms)
    const ctx1 = PromptContext{
        .cwd = "/home/user/zap",
        .home = "/home/user",
        .status_code = 0,
        .cmd_duration = 3500,
    };

    try render(writer, cfg, ctx1);
    const expected1 = "\x1b[1;36m~/zap\x1b[0m took \x1b[1;33m3s\x1b[0m \x1b[1;32m❯\x1b[0m ";
    try testing.expectEqualStrings(expected1, buf[0..pos]);

    // Case 2: duration below min_time (1000ms) -> cmd_duration is hidden
    pos = 0;
    const ctx2 = PromptContext{
        .cwd = "/home/user/zap",
        .home = "/home/user",
        .status_code = 0,
        .cmd_duration = 1000,
    };

    try render(writer, cfg, ctx2);
    const expected2 = "\x1b[1;36m~/zap\x1b[0m \x1b[1;32m❯\x1b[0m ";
    try testing.expectEqualStrings(expected2, buf[0..pos]);
}

test "unit: render prompt with git_status module variables" {
    var buf: [1024]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);
    var cfg: config_mod.Config = config_mod.defaultConfig();
    cfg.add_newline = false;
    cfg.format = "$directory$git_branch$git_status$character";

    try formatter.formatTemplateWriter(writer, cfg.format, formatter.FormatContext(ModuleVar){
        .vars = &[_]formatter.Variable(ModuleVar){
            .{ .name = .directory, .value = "\x1b[1;36m~/zap\x1b[0m " },
            .{ .name = .git_branch, .value = "on \x1b[1;35mmain\x1b[0m " },
            .{ .name = .git_status, .value = "\x1b[1;31m[!+]\x1b[0m " },
            .{ .name = .character, .value = "\x1b[1;32m❯\x1b[0m " },
        },
    });

    const expected = "\x1b[1;36m~/zap\x1b[0m on \x1b[1;35mmain\x1b[0m \x1b[1;31m[!+]\x1b[0m \x1b[1;32m❯\x1b[0m ";
    try testing.expectEqualStrings(expected, buf[0..pos]);
}

test "unit: render prompt with all git modules in root format" {
    var buf: [1024]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);
    var cfg: config_mod.Config = config_mod.defaultConfig();
    cfg.add_newline = false;
    cfg.format = "$directory$git_branch$git_commit$git_state$git_status$character";

    try formatter.formatTemplateWriter(writer, cfg.format, formatter.FormatContext(ModuleVar){
        .vars = &[_]formatter.Variable(ModuleVar){
            .{ .name = .directory, .value = "\x1b[1;36m~/zap\x1b[0m " },
            .{ .name = .git_branch, .value = "on \x1b[1;35mmain\x1b[0m " },
            .{ .name = .git_commit, .value = "\x1b[1;32m(4cd65cc)\x1b[0m " },
            .{ .name = .git_state, .value = "(\x1b[1;33mREBASING 1/3\x1b[0m) " },
            .{ .name = .git_status, .value = "\x1b[1;31m[!+]\x1b[0m " },
            .{ .name = .character, .value = "\x1b[1;32m❯\x1b[0m " },
        },
    });

    const expected = "\x1b[1;36m~/zap\x1b[0m on \x1b[1;35mmain\x1b[0m \x1b[1;32m(4cd65cc)\x1b[0m (\x1b[1;33mREBASING 1/3\x1b[0m) \x1b[1;31m[!+]\x1b[0m \x1b[1;32m❯\x1b[0m ";
    try testing.expectEqualStrings(expected, buf[0..pos]);
}

test "unit: computeActiveModulesMask bitmask calculation" {
    // 0: directory, 1: git_branch, 2: git_commit, 3: git_state, 4: git_status, 5: cmd_duration, 6: character
    const mask1 = computeActiveModulesMask("$directory$character");
    try testing.expectEqual(@as(u16, (1 << 0) | (1 << 6)), mask1);

    const mask2 = computeActiveModulesMask("[$directory](cyan) \\$escaped [$cmd_duration](yellow) $character");
    try testing.expectEqual(@as(u16, (1 << 0) | (1 << 5) | (1 << 6)), mask2);

    const mask_none = computeActiveModulesMask("plain text without modules");
    try testing.expectEqual(@as(u16, 0), mask_none);
}

const Harness = @import("../tests/harness.zig").Harness;

test "integration: prompt render latency under 1ms in real git repo" {
    var h = try Harness.create(testing.allocator);
    defer h.destroy();

    try h.setupGit();
    try h.writeFile("dirty.txt", "modified content");
    try h.writeFile("untracked.txt", "untracked");
    try h.git(&.{ "checkout", "-b", "perf-benchmark-branch" });

    try h.setConfig(
        \\format = "$directory$git_branch$git_status$character"
        \\add_newline = false
    );

    // Warm up subprocess collection
    const warm_out = try h.collect(.generic);
    try Harness.expectContains(warm_out, "perf-benchmark-branch");

    // In-process hot render benchmark across 100 iterations with direct .git/HEAD inspection
    var buf: [2048]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);
    var cfg = config_mod.defaultConfig();
    cfg.format = "$directory$git_branch$character";
    const io = std.testing.io;

    const in_proc_start = std.Io.Clock.awake.now(io);
    const in_proc_iters: i96 = 100;
    for (0..in_proc_iters) |_| {
        pos = 0;
        try render(writer, cfg, .{
            .cwd = h.tmp_dir,
            .home = h.tmp_dir,
            .io = io,
            .status_code = 0,
            .shell = .bash,
        });
    }
    const in_proc_total_ns = in_proc_start.untilNow(io, .awake).toNanoseconds();
    const avg_in_proc_ns = @divTrunc(in_proc_total_ns, in_proc_iters);

    // Direct in-process render must be strictly under 1 millisecond (1,000,000 ns)
    try testing.expect(avg_in_proc_ns < 1_000_000);
}

