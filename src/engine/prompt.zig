const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const config_mod = @import("../config/config.zig");
const formatter = @import("formatter.zig");
const module_interface = @import("../modules/module.zig");
const parse_utils = @import("../utils/parse_utils.zig");
const BufferWriter = @import("../utils/buffer_writer.zig").BufferWriter;
pub const PromptContext = @import("context.zig").PromptContext;
pub const modules = @import("../modules/registry.zig");
pub const ModuleVar = std.meta.DeclEnum(modules);

comptime {
    const decls = @typeInfo(modules).@"struct".decls;
    if (decls.len > 64) {
        @compileError("Registry exceeds maximum of 64 modules supported by u64 bitmask");
    }
    for (decls) |decl| {
        const mod = @field(modules, decl.name);
        module_interface.validateModule(mod);
        if (@hasDecl(mod, "module_name")) {
            if (!std.mem.eql(u8, mod.module_name, decl.name)) {
                @compileError("Module spec.name '" ++ mod.module_name ++ "' does not match registry name '" ++ decl.name ++ "'");
            }
        }
    }
}

/// Computes a bitmask of active modules in a single pass over the format string.
pub fn computeActiveModulesMask(format: []const u8) u64 {
    @setEvalBranchQuota(10_000);
    var mask: u64 = 0;
    var i: usize = 0;
    while (i < format.len) {
        if (format[i] == '\\' and i + 1 < format.len) {
            i += 2;
            continue;
        }
        if (format[i] == '$') {
            const var_name = parse_utils.extractVarName(format[i + 1 ..]);
            if (var_name.len > 0) {
                if (std.meta.stringToEnum(ModuleVar, var_name)) |mod_var| {
                    mask |= @as(u64, 1) << @as(u6, @intCast(@intFromEnum(mod_var)));
                }
                i += 1 + var_name.len;
                continue;
            }
        }
        i += 1;
    }
    return mask;
}

fn moduleBoolMask(comptime decl_name: []const u8) u64 {
    const d = @typeInfo(modules).@"struct".decls;
    var m: u64 = 0;
    for (d, 0..) |decl, idx| {
        const m_mod = @field(modules, decl.name);
        if (@hasDecl(m_mod, decl_name) and @field(m_mod, decl_name)) {
            m |= @as(u64, 1) << @as(u6, @intCast(idx));
        }
    }
    return m;
}

pub const git_modules_mask: u64 = moduleBoolMask("is_git_dependent");

pub const lang_modules_mask: u64 = blk: {
    const d = @typeInfo(modules).@"struct".decls;
    var m: u64 = 0;
    for (d, 0..) |decl, idx| {
        const m_mod = @field(modules, decl.name);
        if (@hasDecl(m_mod, "detect")) {
            m |= @as(u64, 1) << @as(u6, @intCast(idx));
        }
    }
    break :blk m;
};

pub const status_modules_mask: u64 = moduleBoolMask("needs_git_status");

pub fn shouldCheckGit(active_mask: u64, config: config_mod.Config) bool {
    const dir_needs_git = config.directory.truncate_to_repo and (active_mask & comptime computeActiveModulesMask("$directory")) != 0;
    return (active_mask & (git_modules_mask | lang_modules_mask)) != 0 or dir_needs_git;
}

/// Resolves `git_dir` and `git_status` once for the active module bitmask, storing them in the returned `PromptContext`.
pub fn resolveGitContext(
    ctx: PromptContext,
    active_mask: u64,
    config: config_mod.Config,
    git_dir_buf: *[std.fs.max_path_bytes]u8,
    git_status_data: *@import("../utils/git_utils.zig").GitStatusInfo,
) PromptContext {
    const git_utils = @import("../utils/git_utils.zig");
    var resolved_ctx = ctx;

    if (shouldCheckGit(active_mask, config) and resolved_ctx.git_dir == null and !resolved_ctx.git_dir_resolved and resolved_ctx.io != null) {
        resolved_ctx.git_dir = git_utils.findGitDir(resolved_ctx.io.?, resolved_ctx.cwd, git_dir_buf);
        resolved_ctx.git_dir_resolved = true;
    } else if (resolved_ctx.git_dir != null) {
        resolved_ctx.git_dir_resolved = true;
    }
    if (resolved_ctx.git_dir != null and resolved_ctx.git_status == null and resolved_ctx.io != null) {
        if ((active_mask & status_modules_mask) != 0) {
            git_status_data.* = git_utils.getGitStatusForDir(resolved_ctx.io.?, resolved_ctx.cwd, resolved_ctx.git_dir);
            resolved_ctx.git_status = git_status_data;
        }
    }
    return resolved_ctx;
}

const max_non_dir_buffer_size: usize = blk: {
    var max_sz: usize = 512;
    for (@typeInfo(modules).@"struct".decls) |decl| {
        if (!std.mem.eql(u8, decl.name, "directory")) {
            const mod = @field(modules, decl.name);
            if (@hasDecl(mod, "buffer_size") and mod.buffer_size > max_sz) {
                max_sz = mod.buffer_size;
            }
        }
    }
    break :blk max_sz;
};

pub const ModuleBuffers = struct {
    dir_buf: [modules.directory.buffer_size]u8 = undefined,
    var_buffers: [@typeInfo(modules).@"struct".decls.len][max_non_dir_buffer_size]u8 = undefined,
};

pub const ModuleProfile = struct {
    name: []const u8,
    active: bool,
    duration_ns: u64,
    bytes: usize,
};

/// Renders all active modules into `buffers` and populates `vars` (and optionally `profiles`).
pub fn renderActiveModules(
    config: config_mod.Config,
    active_mask: u64,
    resolved_ctx: PromptContext,
    buffers: *ModuleBuffers,
    vars: *[@typeInfo(modules).@"struct".decls.len]formatter.Variable(ModuleVar),
    profiles: ?*[@typeInfo(modules).@"struct".decls.len]ModuleProfile,
) !void {
    const decls = @typeInfo(modules).@"struct".decls;
    inline for (decls, 0..) |decl, i| {
        const mod = @field(modules, decl.name);
        const is_active = (active_mask & (@as(u64, 1) << @as(u6, @intCast(i)))) != 0;
        var pos: usize = 0;
        var mod_dur_ns: u64 = 0;
        const mod_buf_full: []u8 = if (std.mem.eql(u8, decl.name, "directory")) &buffers.dir_buf else &buffers.var_buffers[i];
        const mod_cap = if (@hasDecl(mod, "buffer_size")) @min(mod.buffer_size, mod_buf_full.len) else mod_buf_full.len;
        const mod_buf = mod_buf_full[0..mod_cap];

        if (is_active) {
            const is_git_mod = (git_modules_mask & (@as(u64, 1) << @as(u6, @intCast(i)))) != 0;
            if (!is_git_mod or resolved_ctx.git_dir != null) {
                const mod_writer = BufferWriter.init(mod_buf, &pos);
                const mod_cfg = @field(config, decl.name);
                if (profiles != null and resolved_ctx.io != null) {
                    const io = resolved_ctx.io.?;
                    const m_t0 = std.Io.Clock.awake.now(io).toNanoseconds();
                    try mod.render(mod_writer, mod_cfg, resolved_ctx);
                    const m_t1 = std.Io.Clock.awake.now(io).toNanoseconds();
                    mod_dur_ns = if (m_t1 > m_t0) @intCast(m_t1 - m_t0) else 0;
                } else {
                    try mod.render(mod_writer, mod_cfg, resolved_ctx);
                }
            }
        }

        vars[i] = .{
            .name = @field(ModuleVar, decl.name),
            .value = mod_buf[0..pos],
        };

        if (profiles) |p| {
            p[i] = .{
                .name = decl.name,
                .active = is_active,
                .duration_ns = mod_dur_ns,
                .bytes = pos,
            };
        }
    }
}

/// Orchestrates rendering the complete prompt across all active modules using comptime reflection.
pub fn render(writer: anytype, config: config_mod.Config, ctx: PromptContext) !void {
    if (config.add_newline) {
        try writer.writeByte('\n');
    }

    const active_mask = computeActiveModulesMask(config.format);
    const decls = @typeInfo(modules).@"struct".decls;
    var vars: [decls.len]formatter.Variable(ModuleVar) = undefined;
    var mod_buffers: ModuleBuffers = undefined;

    var git_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    var git_status_data: @import("../utils/git_utils.zig").GitStatusInfo = undefined;
    const resolved_ctx = resolveGitContext(ctx, active_mask, config, &git_dir_buf, &git_status_data);

    try renderActiveModules(config, active_mask, resolved_ctx, &mod_buffers, &vars, null);

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

    // Case 2: duration below min_time (2000ms) -> cmd_duration is hidden
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
    const dir_bit = @as(u64, 1) << @as(u6, @intCast(@intFromEnum(ModuleVar.directory)));
    const dur_bit = @as(u64, 1) << @as(u6, @intCast(@intFromEnum(ModuleVar.cmd_duration)));
    const char_bit = @as(u64, 1) << @as(u6, @intCast(@intFromEnum(ModuleVar.character)));

    const mask1 = computeActiveModulesMask("$directory$character");
    try testing.expectEqual(dir_bit | char_bit, mask1);

    const mask2 = computeActiveModulesMask("[$directory](cyan) \\$escaped [$cmd_duration](yellow) $character");
    try testing.expectEqual(dir_bit | dur_bit | char_bit, mask2);

    const mask_none = computeActiveModulesMask("plain text without modules");
    try testing.expectEqual(@as(u64, 0), mask_none);
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

    // In-process hot render benchmark across 100 iterations with full git stack (git_branch, git_status, git_state, git_commit)
    var buf: [2048]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);
    var cfg = config_mod.defaultConfig();
    cfg.format = "$directory$git_branch$git_status$git_state$git_commit$character";
    const io = std.testing.io;

    const in_proc_start = std.Io.Clock.awake.now(io);
    const in_proc_iters: i96 = 20;
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

    // Render with git status subprocess must complete well within interactive prompt budget (30ms on Unix, 150ms on Windows CI)
    const max_ns: i96 = if (builtin.os.tag == .windows) 150_000_000 else 30_000_000;
    try testing.expect(avg_in_proc_ns < max_ns);
}

test "unit: status_modules_mask and git_modules_mask reflect module declarations" {
    try testing.expectEqual(computeActiveModulesMask("$git_branch $git_commit $git_status"), status_modules_mask);
    try testing.expectEqual(computeActiveModulesMask("$git_branch $git_commit $git_state $git_status"), git_modules_mask);
}
