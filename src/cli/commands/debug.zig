const std = @import("std");
const registry = @import("../../modules/registry.zig");
const context = @import("../../engine/context.zig");
const config_mod = @import("../../config/config.zig");
const toml_parser = @import("../../config/toml_parser.zig");
const prompt_engine = @import("../../engine/prompt.zig");
const formatter = @import("../../engine/formatter.zig");
const git_utils = @import("../../utils/git_utils.zig");
const PromptContext = context.PromptContext;
const DebugContext = context.DebugContext;
const BufferWriter = @import("../../utils/buffer_writer.zig").BufferWriter;

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
    const cwd = resolveCwdPath(init, &cwd_buf);
    const home = resolveHomePath(init);

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

    const target_str = args.module_name orelse "git";
    const target_enum_opt = std.meta.stringToEnum(DebugTarget, target_str);

    if (target_enum_opt) |target_enum| {
        switch (target_enum) {
            .git => {
                if (dctx.verbose) {
                    try printGitVerboseDebug(init, writer, dctx);
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
            .config => try printConfigDebug(init, writer, dctx),
            .bench, .profile, .prompt => try printPromptProfileDebug(init, writer, dctx),
            .env, .shell => try printEnvDebug(init, writer, dctx),
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

fn resolveHomePath(init: std.process.Init) []const u8 {
    return init.environ_map.get("HOME") orelse init.environ_map.get("USERPROFILE") orelse ".";
}

fn resolveCwdPath(init: std.process.Init, buf: *[std.fs.max_path_bytes]u8) []const u8 {
    if (init.environ_map.get("PWD")) |pwd| {
        return pwd;
    }

    const cwd: std.Io.Dir = .cwd();
    const pwd_file = cwd.openFile(init.io, ".", .{}) catch return ".";
    defer pwd_file.close(init.io);

    const len = pwd_file.realPath(init.io, buf) catch return ".";
    return buf[0..len];
}

fn printGitVerboseDebug(init: std.process.Init, writer: anytype, dctx: DebugContext) !void {
    _ = init;
    const io = dctx.prompt.io orelse return;

    var start_ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 0 };
    if (@import("builtin").os.tag == .linux) {
        _ = std.os.linux.clock_gettime(.MONOTONIC, &start_ts);
    }

    var git_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const git_dir_opt = dctx.prompt.git_dir orelse git_utils.findGitDir(io, dctx.prompt.cwd, &git_dir_buf);

    if (git_dir_opt == null) {
        if (dctx.json) {
            try writer.writeAll("{\"in_git_repo\": false}\n");
        } else {
            try writer.print("⚡ Zap Git Inspector (Verbose)\n\n✖ Not a git repository (cwd: {s})\n", .{dctx.prompt.cwd});
        }
        return;
    }

    const git_dir = git_dir_opt.?;
    const repo_root = git_utils.gitDirToRepoRoot(git_dir);

    var branch_buf: [512]u8 = undefined;
    const branch_opt = git_utils.getGitBranchFromDir(io, git_dir, &branch_buf);
    const branch_name = branch_opt orelse "DETACHED HEAD";

    var head_buf: [512]u8 = undefined;
    var ref_buf: [512]u8 = undefined;
    const commit_info = git_utils.getGitCommit(io, git_dir, &head_buf, &ref_buf);
    var ab = git_utils.git.ahead_behind.AheadBehindResult{};
    if (branch_opt) |b| {
        ab = git_utils.getAheadBehind(io, git_dir, b);
    }
    const status = git_utils.getGitStatusForDir(io, dctx.prompt.cwd, git_dir, branch_opt);
    const index_scan = git_utils.scanGitIndex(io, git_dir, repo_root);

    var cur_buf: [32]u8 = undefined;
    var total_buf: [32]u8 = undefined;
    const git_state = git_utils.getGitState(io, git_dir, &cur_buf, &total_buf);

    var collector = git_utils.GitFileCollector{};
    git_utils.collectDetailedGitFiles(io, git_dir, repo_root, &collector);

    const is_worktree = !std.mem.endsWith(u8, git_dir, "/.git") and !std.mem.eql(u8, git_dir, ".git");

    var elapsed_us: u64 = 0;
    if (@import("builtin").os.tag == .linux) {
        var end_ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 0 };
        _ = std.os.linux.clock_gettime(.MONOTONIC, &end_ts);
        const sec_diff = end_ts.sec - start_ts.sec;
        const nsec_diff = end_ts.nsec - start_ts.nsec;
        const total_ns = @as(u64, @intCast(@max(0, sec_diff * 1_000_000_000 + nsec_diff)));
        elapsed_us = @divTrunc(total_ns, 1000);
    }

    if (dctx.json) {
        try writer.print(
            \\{{ "module": "git", "verbose": true, "in_git_repo": true, "repo_root": "{s}", "git_dir": "{s}", "is_worktree": {}, "branch": "{s}", "commit": "{s}", "tag": "{s}", "detached": {}, "ahead": {d}, "behind": {d}, "index_entries": {d}, "status": {{ "staged": {}, "modified": {}, "untracked": {}, "deleted": {}, "stashed": {}, "conflicted": {} }}, "files": {{ "modified": [
        , .{
            repo_root,
            git_dir,
            is_worktree,
            branch_name,
            if (commit_info) |c| c.hash else "",
            if (commit_info) |c| c.tag else "",
            if (commit_info) |c| c.is_detached else false,
            ab.ahead,
            ab.behind,
            index_scan.entry_count,
            status.staged,
            status.modified,
            status.untracked,
            status.deleted,
            status.stashed,
            status.conflicted,
        });

        var m_idx: usize = 0;
        while (m_idx < collector.modified_count) : (m_idx += 1) {
            if (m_idx > 0) try writer.writeAll(", ");
            try writer.print("\"{s}\"", .{collector.getModified(m_idx)});
        }
        try writer.writeAll("], \"untracked\": [");
        var u_idx: usize = 0;
        while (u_idx < collector.untracked_count) : (u_idx += 1) {
            if (u_idx > 0) try writer.writeAll(", ");
            try writer.print("\"{s}\"", .{collector.getUntracked(u_idx)});
        }
        try writer.writeAll("], \"deleted\": [");
        var d_idx: usize = 0;
        while (d_idx < collector.deleted_count) : (d_idx += 1) {
            if (d_idx > 0) try writer.writeAll(", ");
            try writer.print("\"{s}\"", .{collector.getDeleted(d_idx)});
        }
        try writer.writeAll("], \"conflicted\": [");
        var c_idx: usize = 0;
        while (c_idx < collector.conflicted_count) : (c_idx += 1) {
            if (c_idx > 0) try writer.writeAll(", ");
            try writer.print("\"{s}\"", .{collector.getConflicted(c_idx)});
        }
        try writer.print(
            \\ ] }}, "state": "{s}", "scan_duration_us": {d} }}
            \\
        , .{
            @tagName(git_state.state_type),
            elapsed_us,
        });
    } else {
        try writer.print(
            \\⚡ Zap Git Diagnostic Inspector (Verbose Mode)
            \\
            \\Repository:
            \\  Repo Root:        {s}
            \\  Git Dir:          {s}
            \\  Worktree:         {s}
            \\  Index Entries:    {d} tracked files
            \\
            \\Reference & Commit:
            \\  Branch:           {s}
            \\  Commit SHA:       {s}
            \\  Tag:              {s}
            \\  HEAD Detached:    {}
            \\
            \\Ahead / Behind:
            \\  Ahead (⇡):        {d} commits
            \\  Behind (⇣):       {d} commits
            \\
            \\Status Flags:
            \\  Staged (+):       {}
            \\  Modified (!):     {} ({d} files)
            \\  Untracked (?):    {} ({d} files)
            \\  Deleted (✘):      {} ({d} files)
            \\  Stashed ($):      {}
            \\  Conflicted (=):   {} ({d} files)
            \\
            \\Modified Files (!):
            \\
        , .{
            repo_root,
            git_dir,
            if (is_worktree) "Yes (linked worktree)" else "No (standard repository)",
            index_scan.entry_count,
            branch_name,
            if (commit_info) |c| c.hash else "none",
            if (commit_info) |c| (if (c.tag.len > 0) c.tag else "none") else "none",
            if (commit_info) |c| c.is_detached else false,
            ab.ahead,
            ab.behind,
            status.staged,
            status.modified,
            collector.modified_count,
            status.untracked,
            collector.untracked_count,
            status.deleted,
            collector.deleted_count,
            status.stashed,
            status.conflicted,
            collector.conflicted_count,
        });

        if (collector.modified_count == 0) {
            try writer.writeAll("  (none)\n");
        } else {
            var i: usize = 0;
            while (i < collector.modified_count) : (i += 1) {
                try writer.print("  - {s}\n", .{collector.getModified(i)});
            }
        }

        try writer.writeAll("\nUntracked Files (?):\n");
        if (collector.untracked_count == 0) {
            try writer.writeAll("  (none)\n");
        } else {
            var i: usize = 0;
            while (i < collector.untracked_count) : (i += 1) {
                try writer.print("  - {s}\n", .{collector.getUntracked(i)});
            }
        }

        try writer.writeAll("\nDeleted Files (✘):\n");
        if (collector.deleted_count == 0) {
            try writer.writeAll("  (none)\n");
        } else {
            var i: usize = 0;
            while (i < collector.deleted_count) : (i += 1) {
                try writer.print("  - {s}\n", .{collector.getDeleted(i)});
            }
        }

        try writer.writeAll("\nConflicted Files (=):\n");
        if (collector.conflicted_count == 0) {
            try writer.writeAll("  (none)\n");
        } else {
            var i: usize = 0;
            while (i < collector.conflicted_count) : (i += 1) {
                try writer.print("  - {s}\n", .{collector.getConflicted(i)});
            }
        }

        try writer.print(
            \\
            \\Operation State:
            \\  State:            {s}
            \\
            \\Performance:
            \\  Scan Duration:    {d} µs ({d}.{d:0>3} ms)
            \\
        , .{
            @tagName(git_state.state_type),
            elapsed_us,
            @divTrunc(elapsed_us, 1000),
            @mod(elapsed_us, 1000),
        });
    }
}

fn printConfigDebug(init: std.process.Init, writer: anytype, dctx: DebugContext) !void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const config_path_opt = toml_parser.resolveExistingConfigPath(init.io, &path_buf, init.environ_map);

    var config = config_mod.defaultConfig();
    var config_file_buf: [64 * 1024]u8 = undefined;
    var file_size: usize = 0;

    if (config_path_opt) |config_path| {
        const file = if (std.fs.path.isAbsolute(config_path))
            std.Io.Dir.openFileAbsolute(init.io, config_path, .{}) catch null
        else
            std.Io.Dir.cwd().openFile(init.io, config_path, .{}) catch null;

        if (file) |f| {
            var handle = f;
            defer handle.close(init.io);
            var stream_buf: [4096]u8 = undefined;
            var reader = handle.reader(init.io, &stream_buf);
            file_size = reader.interface.readSliceShort(&config_file_buf) catch 0;
            if (file_size > 0) {
                toml_parser.parseToml(&config, config_file_buf[0..file_size]);
            }
        }
    }

    const active_mask = prompt_engine.computeActiveModulesMask(config.format);
    const decls = @typeInfo(registry).@"struct".decls;

    if (dctx.json) {
        try writer.print(
            \\{{ "config_path": {s}{s}{s}, "file_size": {d}, "format": "{s}", "add_newline": {}, "active_modules": [
        , .{
            if (config_path_opt != null) "\"" else "",
            if (config_path_opt) |p| p else "null",
            if (config_path_opt != null) "\"" else "",
            file_size,
            config.format,
            config.add_newline,
        });

        var first_active = true;
        inline for (decls, 0..) |decl, idx| {
            const is_active = (active_mask & (@as(u64, 1) << @as(u6, @intCast(idx)))) != 0;
            if (is_active) {
                if (!first_active) try writer.writeAll(", ");
                try writer.print("\"{s}\"", .{decl.name});
                first_active = false;
            }
        }

        try writer.writeAll("], \"inactive_modules\": [");
        var first_inactive = true;
        inline for (decls, 0..) |decl, idx| {
            const is_active = (active_mask & (@as(u64, 1) << @as(u6, @intCast(idx)))) != 0;
            if (!is_active) {
                if (!first_inactive) try writer.writeAll(", ");
                try writer.print("\"{s}\"", .{decl.name});
                first_inactive = false;
            }
        }
        try writer.writeAll("]");

        if (dctx.verbose) {
            try writer.writeAll(", \"verbose\": true, \"modules\": {");
            var first_mod = true;
            inline for (decls) |decl| {
                if (!first_mod) try writer.writeAll(", ");
                const mod_cfg = @field(config, decl.name);
                try writer.print("\"{s}\": {{", .{decl.name});
                var first_f = true;
                inline for (@typeInfo(@TypeOf(mod_cfg)).@"struct".fields) |f| {
                    const val = @field(mod_cfg, f.name);
                    if (f.type == []const u8) {
                        if (!first_f) try writer.writeAll(", ");
                        try writer.print("\"{s}\": \"{s}\"", .{ f.name, val });
                        first_f = false;
                    } else if (f.type == bool) {
                        if (!first_f) try writer.writeAll(", ");
                        try writer.print("\"{s}\": {}", .{ f.name, val });
                        first_f = false;
                    } else if (f.type == usize or f.type == u32 or f.type == u64) {
                        if (!first_f) try writer.writeAll(", ");
                        try writer.print("\"{s}\": {d}", .{ f.name, val });
                        first_f = false;
                    }
                }
                try writer.writeAll("}");
                first_mod = false;
            }
            try writer.writeAll("}");
        }

        try writer.writeAll(" }\n");
    } else {
        try writer.print(
            \\⚡ Zap Config Inspector{s}
            \\
            \\Config File:
            \\  Loaded From:     {s}
            \\  File Size:       {d} bytes
            \\
            \\Root Settings:
            \\  Add Newline:     {}
            \\  Format:          "{s}"
            \\
            \\Active Modules:
            \\
        , .{
            if (dctx.verbose) " (Verbose Mode)" else "",
            if (config_path_opt) |p| p else "Default built-in configuration (no file found)",
            file_size,
            config.add_newline,
            config.format,
        });

        inline for (decls, 0..) |decl, idx| {
            const is_active = (active_mask & (@as(u64, 1) << @as(u6, @intCast(idx)))) != 0;
            if (is_active) {
                try writer.print("  ✔ {s}\n", .{decl.name});
            }
        }

        try writer.writeAll("\nInactive (Skipped by bitmask):\n");
        inline for (decls, 0..) |decl, idx| {
            const is_active = (active_mask & (@as(u64, 1) << @as(u6, @intCast(idx)))) != 0;
            if (!is_active) {
                try writer.print("  · {s}\n", .{decl.name});
            }
        }

        if (dctx.verbose) {
            try writer.writeAll("\nModule Configurations (Verbose):\n");
            inline for (decls) |decl| {
                const mod_cfg = @field(config, decl.name);
                try writer.print("  [{s}]\n", .{decl.name});
                inline for (@typeInfo(@TypeOf(mod_cfg)).@"struct".fields) |f| {
                    const val = @field(mod_cfg, f.name);
                    if (f.type == []const u8) {
                        try writer.print("    {s:<18}: \"{s}\"\n", .{ f.name, val });
                    } else if (f.type == bool) {
                        try writer.print("    {s:<18}: {}\n", .{ f.name, val });
                    } else if (f.type == usize or f.type == u32 or f.type == u64) {
                        try writer.print("    {s:<18}: {d}\n", .{ f.name, val });
                    }
                }
                try writer.writeAll("\n");
            }
        } else {
            try writer.writeAll("\n");
        }
    }
}

fn checkFileContains(io: std.Io, path: []const u8, needle: []const u8) bool {
    var buf: [16384]u8 = undefined;
    const file = if (std.fs.path.isAbsolute(path))
        std.Io.Dir.openFileAbsolute(io, path, .{}) catch null
    else
        std.Io.Dir.cwd().openFile(io, path, .{}) catch null;
    if (file) |f| {
        var handle = f;
        defer handle.close(io);
        var stream_buf: [4096]u8 = undefined;
        var reader = handle.reader(io, &stream_buf);
        const bytes_read = reader.interface.readSliceShort(&buf) catch 0;
        if (bytes_read > 0) {
            return std.mem.indexOf(u8, buf[0..bytes_read], needle) != null;
        }
    }
    return false;
}

fn printEnvDebug(init: std.process.Init, writer: anytype, dctx: DebugContext) !void {
    const io = dctx.prompt.io orelse return;

    const shell_env = init.environ_map.get("SHELL") orelse "";
    const shell_name = if (shell_env.len > 0) std.fs.path.basename(shell_env) else "unknown";
    const term = init.environ_map.get("TERM") orelse "unknown";
    const colorterm = init.environ_map.get("COLORTERM") orelse "";
    const term_program = init.environ_map.get("TERM_PROGRAM") orelse "";

    const lang = init.environ_map.get("LC_ALL") orelse init.environ_map.get("LC_CTYPE") orelse init.environ_map.get("LANG") orelse "";
    const is_utf8 = std.mem.indexOf(u8, lang, "UTF-8") != null or std.mem.indexOf(u8, lang, "utf8") != null or std.mem.indexOf(u8, lang, "UTF8") != null;

    const has_truecolor = std.mem.eql(u8, colorterm, "truecolor") or std.mem.eql(u8, colorterm, "24bit");
    const has_256color = has_truecolor or std.mem.indexOf(u8, term, "256color") != null or std.mem.indexOf(u8, term, "256") != null;

    const zap_config_env = init.environ_map.get("ZAP_CONFIG");
    const shlvl = init.environ_map.get("SHLVL") orelse "1";

    var cfg_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const resolved_cfg_path = toml_parser.resolveExistingConfigPath(io, &cfg_path_buf, init.environ_map);

    var bash_hook_path: [std.fs.max_path_bytes]u8 = undefined;
    const bash_rc = std.fmt.bufPrint(&bash_hook_path, "{s}/.bashrc", .{dctx.prompt.home}) catch "";
    const bash_hook = checkFileContains(io, bash_rc, "zap init bash") or checkFileContains(io, bash_rc, "zap prompt");

    var zsh_hook_path: [std.fs.max_path_bytes]u8 = undefined;
    const zsh_rc = std.fmt.bufPrint(&zsh_hook_path, "{s}/.zshrc", .{dctx.prompt.home}) catch "";
    const zsh_hook = checkFileContains(io, zsh_rc, "zap init zsh") or checkFileContains(io, zsh_rc, "zap prompt");

    var fish_hook_path: [std.fs.max_path_bytes]u8 = undefined;
    const fish_rc = std.fmt.bufPrint(&fish_hook_path, "{s}/.config/fish/config.fish", .{dctx.prompt.home}) catch "";
    const fish_hook = checkFileContains(io, fish_rc, "zap init fish") or checkFileContains(io, fish_rc, "zap prompt");

    var pwsh_hook_path: [std.fs.max_path_bytes]u8 = undefined;
    const pwsh_rc = std.fmt.bufPrint(&pwsh_hook_path, "{s}/.config/powershell/Microsoft.PowerShell_profile.ps1", .{dctx.prompt.home}) catch "";
    const pwsh_hook = checkFileContains(io, pwsh_rc, "zap init powershell") or checkFileContains(io, pwsh_rc, "zap prompt");

    if (dctx.json) {
        try writer.print(
            \\{{ "target": "env", "shell": "{s}", "shell_path": "{s}", "term": "{s}", "term_program": "{s}", "color_support": {{ "truecolor": {}, "color_256": {} }}, "utf8_locale": {}, "locale": "{s}", "variables": {{ "HOME": "{s}", "PWD": "{s}", "ZAP_CONFIG": {s}{s}{s}, "SHLVL": "{s}" }}, "config": {{ "resolved_path": {s}{s}{s}, "exists": {} }}, "hooks": {{ "bash": {}, "zsh": {}, "fish": {}, "powershell": {} }} }}
            \\
        , .{
            shell_name,
            shell_env,
            term,
            term_program,
            has_truecolor,
            has_256color,
            is_utf8,
            lang,
            dctx.prompt.home,
            dctx.prompt.cwd,
            if (zap_config_env != null) "\"" else "",
            if (zap_config_env) |zc| zc else "null",
            if (zap_config_env != null) "\"" else "",
            shlvl,
            if (resolved_cfg_path != null) "\"" else "",
            if (resolved_cfg_path) |rc| rc else "null",
            if (resolved_cfg_path != null) "\"" else "",
            resolved_cfg_path != null,
            bash_hook,
            zsh_hook,
            fish_hook,
            pwsh_hook,
        });
    } else {
        try writer.print(
            \\⚡ Zap Environment & Terminal Inspector
            \\
            \\Terminal & Display:
            \\  Detected Shell:    {s} ({s})
            \\  Terminal ($TERM):  {s}{s}{s}
            \\  Color Support:     {s}
            \\  Locale (UTF-8):    {s} ({s})
            \\
            \\Key Environment Variables:
            \\  $HOME:             {s}
            \\  $PWD:              {s}
            \\  $ZAP_CONFIG:       {s}
            \\  $SHLVL:            {s}
            \\
            \\Zap Configuration:
            \\  Resolved Path:     {s}
            \\
            \\Shell Integration Hooks:
            \\  {s} bash:           {s} ({s})
            \\  {s} zsh:            {s} ({s})
            \\  {s} fish:           {s} ({s})
            \\  {s} powershell:     {s} ({s})
            \\
        , .{
            shell_name,
            if (shell_env.len > 0) shell_env else "none",
            term,
            if (term_program.len > 0) " (" else "",
            if (term_program.len > 0) term_program else "",
            if (has_truecolor) "TrueColor (24-bit) & 256-color" else if (has_256color) "256-color" else "Standard ANSI (16 colors)",
            if (lang.len > 0) lang else "not set",
            if (is_utf8) "UTF-8 supported" else "non-UTF8 or standard ASCII",
            dctx.prompt.home,
            dctx.prompt.cwd,
            if (zap_config_env) |zc| zc else "(not set - using default discovery)",
            shlvl,
            if (resolved_cfg_path) |rc| rc else "Default built-in configuration (no file found)",
            if (bash_hook) "✔" else "·",
            if (bash_hook) "Hook installed" else "Not installed",
            bash_rc,
            if (zsh_hook) "✔" else "·",
            if (zsh_hook) "Hook installed" else "Not installed",
            zsh_rc,
            if (fish_hook) "✔" else "·",
            if (fish_hook) "Hook installed" else "Not installed",
            fish_rc,
            if (pwsh_hook) "✔" else "·",
            if (pwsh_hook) "Hook installed" else "Not installed",
            pwsh_rc,
        });
    }
}

fn getTimestampNs() u64 {
    if (@import("builtin").os.tag == .linux) {
        var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 0 };
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
        const s = @as(u64, @intCast(@max(0, ts.sec)));
        const ns = @as(u64, @intCast(@max(0, ts.nsec)));
        return s * 1_000_000_000 + ns;
    }
    return 0;
}

fn printPromptProfileDebug(init: std.process.Init, writer: anytype, dctx: DebugContext) !void {
    const io = dctx.prompt.io orelse return;

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const config_path_opt = toml_parser.resolveExistingConfigPath(init.io, &path_buf, init.environ_map);

    var config = config_mod.defaultConfig();
    var config_file_buf: [64 * 1024]u8 = undefined;

    if (config_path_opt) |config_path| {
        const file = if (std.fs.path.isAbsolute(config_path))
            std.Io.Dir.openFileAbsolute(init.io, config_path, .{}) catch null
        else
            std.Io.Dir.cwd().openFile(init.io, config_path, .{}) catch null;

        if (file) |f| {
            var handle = f;
            defer handle.close(init.io);
            var stream_buf: [4096]u8 = undefined;
            var reader = handle.reader(init.io, &stream_buf);
            const bytes_read = reader.interface.readSliceShort(&config_file_buf) catch 0;
            if (bytes_read > 0) {
                toml_parser.parseToml(&config, config_file_buf[0..bytes_read]);
            }
        }
    }

    const active_mask = prompt_engine.computeActiveModulesMask(config.format);
    const decls = @typeInfo(registry).@"struct".decls;

    const git_modules_mask = comptime blk: {
        const d = @typeInfo(registry).@"struct".decls;
        var m: u64 = 0;
        for (d, 0..) |decl, idx| {
            const m_mod = @field(registry, decl.name);
            if (@hasDecl(m_mod, "is_git_dependent") and m_mod.is_git_dependent) {
                m |= @as(u64, 1) << @as(u6, @intCast(idx));
            }
        }
        break :blk m;
    };
    const dir_needs_git = config.directory.truncate_to_repo and (active_mask & prompt_engine.computeActiveModulesMask("$directory")) != 0;
    const should_check_git = ((active_mask & git_modules_mask) != 0 or dir_needs_git) and dctx.prompt.git_dir == null;

    var git_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    var resolved_ctx = dctx.prompt;
    var git_dur_ns: u64 = 0;
    if (should_check_git) {
        const t0 = getTimestampNs();
        resolved_ctx.git_dir = git_utils.findGitDir(io, resolved_ctx.cwd, &git_dir_buf);
        const t1 = getTimestampNs();
        git_dur_ns = if (t1 > t0) t1 - t0 else 0;
    }

    const ModuleProfile = struct {
        name: []const u8,
        active: bool,
        duration_ns: u64,
        bytes: usize,
    };

    var profiles: [decls.len]ModuleProfile = undefined;
    var vars: [decls.len]formatter.Variable(prompt_engine.ModuleVar) = undefined;
    var var_buffers: [decls.len][512]u8 = undefined;

    const single_run_t0 = getTimestampNs();

    inline for (decls, 0..) |decl, i| {
        const mod = @field(registry, decl.name);
        const is_active = (active_mask & (@as(u64, 1) << @as(u6, @intCast(i)))) != 0;
        var pos: usize = 0;
        var mod_dur_ns: u64 = 0;

        if (is_active) {
            const is_git_mod = (git_modules_mask & (@as(u64, 1) << @as(u6, @intCast(i)))) != 0;
            if (!is_git_mod or resolved_ctx.git_dir != null) {
                const mod_writer = BufferWriter.init(&var_buffers[i], &pos);
                const mod_cfg = @field(config, decl.name);
                const m_t0 = getTimestampNs();
                try mod.render(mod_writer, mod_cfg, resolved_ctx);
                const m_t1 = getTimestampNs();
                mod_dur_ns = if (m_t1 > m_t0) m_t1 - m_t0 else 0;
            }
        }

        vars[i] = .{
            .name = @field(prompt_engine.ModuleVar, decl.name),
            .value = var_buffers[i][0..pos],
        };

        profiles[i] = .{
            .name = decl.name,
            .active = is_active,
            .duration_ns = mod_dur_ns,
            .bytes = pos,
        };
    }

    var rendered_prompt_buf: [4096]u8 = undefined;
    var rendered_pos: usize = 0;
    const prompt_writer = BufferWriter.init(&rendered_prompt_buf, &rendered_pos);
    if (config.add_newline) {
        try prompt_writer.writeByte('\n');
    }
    const fmt_t0 = getTimestampNs();
    try formatter.formatTemplateWriter(prompt_writer, config.format, formatter.FormatContext(prompt_engine.ModuleVar){
        .vars = &vars,
        .shell = resolved_ctx.shell,
    });
    const fmt_t1 = getTimestampNs();
    const fmt_dur_ns = if (fmt_t1 > fmt_t0) fmt_t1 - fmt_t0 else 0;
    const single_run_t1 = getTimestampNs();
    const single_run_total_ns = if (single_run_t1 > single_run_t0) single_run_t1 - single_run_t0 else 0;

    // Multi-pass benchmark: 100 iterations
    const BenchmarkIterations: usize = 100;
    var min_ns: u64 = std.math.maxInt(u64);
    var max_ns: u64 = 0;
    var total_ns: u64 = 0;

    var bench_iter: usize = 0;
    while (bench_iter < BenchmarkIterations) : (bench_iter += 1) {
        var dummy_buf: [4096]u8 = undefined;
        var dummy_pos: usize = 0;
        const dummy_writer = BufferWriter.init(&dummy_buf, &dummy_pos);

        const b_t0 = getTimestampNs();
        try prompt_engine.render(dummy_writer, config, resolved_ctx);
        const b_t1 = getTimestampNs();
        const b_dur = if (b_t1 > b_t0) b_t1 - b_t0 else 0;

        if (b_dur < min_ns) min_ns = b_dur;
        if (b_dur > max_ns) max_ns = b_dur;
        total_ns += b_dur;
    }

    if (min_ns == std.math.maxInt(u64)) min_ns = 0;
    const mean_ns = if (BenchmarkIterations > 0) total_ns / BenchmarkIterations else 0;
    const throughput = if (mean_ns > 0) (1_000_000_000 / mean_ns) else 0;

    if (dctx.json) {
        try writer.print(
            \\{{ "target": "prompt_profiler", "total_render_us": {d}, "format_duration_us": {d}, "git_discovery_us": {d}, "buffer_used_bytes": {d}, "buffer_capacity_bytes": {d}, "modules": [
        , .{
            @divTrunc(single_run_total_ns, 1000),
            @divTrunc(fmt_dur_ns, 1000),
            @divTrunc(git_dur_ns, 1000),
            rendered_pos,
            rendered_prompt_buf.len,
        });

        for (profiles, 0..) |p, i| {
            if (i > 0) try writer.writeAll(", ");
            try writer.print(
                \\{{ "name": "{s}", "active": {}, "duration_us": {d}, "bytes": {d} }}
            , .{
                p.name,
                p.active,
                @divTrunc(p.duration_ns, 1000),
                p.bytes,
            });
        }

        try writer.print(
            \\ ], "benchmark": {{ "iterations": {d}, "min_us": {d}, "mean_us": {d}, "max_us": {d}, "throughput_renders_per_sec": {d} }} }}
            \\
        , .{
            BenchmarkIterations,
            @divTrunc(min_ns, 1000),
            @divTrunc(mean_ns, 1000),
            @divTrunc(max_ns, 1000),
            throughput,
        });
    } else {
        try writer.print(
            \\⚡ Zap Prompt Engine Profiler & Benchmark
            \\
            \\Configuration:
            \\  Add Newline:      {}
            \\  Buffer Usage:     {d} / {d} bytes ({d}.{d}% utilized)
            \\
            \\Per-Module Execution Breakdown (Single Pass):
            \\
        , .{
            config.add_newline,
            rendered_pos,
            rendered_prompt_buf.len,
            (rendered_pos * 100) / rendered_prompt_buf.len,
            ((rendered_pos * 1000) / rendered_prompt_buf.len) % 10,
        });

        for (profiles) |p| {
            if (p.active) {
                const mod_us = @divTrunc(p.duration_ns, 1000);
                const percent = if (single_run_total_ns > 0) (p.duration_ns * 100) / single_run_total_ns else 0;
                try writer.print("  ✔ {s:<15} {d:>6} µs  [{d:>3}%]  ({d} bytes)\n", .{ p.name, mod_us, percent, p.bytes });
            } else {
                try writer.print("  · {s:<15}      0 µs  (inactive)\n", .{p.name});
            }
        }

        try writer.print(
            \\
            \\Pipeline Stages:
            \\  Git Resolution:   {d:>6} µs
            \\  Template Format:  {d:>6} µs
            \\  Total Single-Run: {d:>6} µs ({d}.{d:0>3} ms)
            \\
            \\Multi-Pass Benchmark ({d} iterations):
            \\  Fastest (Min):    {d:>6} µs ({d}.{d:0>3} ms)
            \\  Average (Mean):   {d:>6} µs ({d}.{d:0>3} ms)
            \\  Slowest (Max):    {d:>6} µs ({d}.{d:0>3} ms)
            \\  Throughput:       {d} renders/sec
            \\
        , .{
            @divTrunc(git_dur_ns, 1000),
            @divTrunc(fmt_dur_ns, 1000),
            @divTrunc(single_run_total_ns, 1000),
            @divTrunc(single_run_total_ns, 1_000_000),
            @divTrunc(@mod(single_run_total_ns, 1_000_000), 1000),
            BenchmarkIterations,
            @divTrunc(min_ns, 1000),
            @divTrunc(min_ns, 1_000_000),
            @divTrunc(@mod(min_ns, 1_000_000), 1000),
            @divTrunc(mean_ns, 1000),
            @divTrunc(mean_ns, 1_000_000),
            @divTrunc(@mod(mean_ns, 1_000_000), 1000),
            @divTrunc(max_ns, 1000),
            @divTrunc(max_ns, 1_000_000),
            @divTrunc(@mod(max_ns, 1_000_000), 1000),
            throughput,
        });
    }
}

const testing = std.testing;
const Harness = @import("../../tests/harness.zig").Harness;

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
    const file_content = @import("../../utils/fs.zig").readSmallFile(std.testing.io, full_path, &read_buf) orelse "";

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
