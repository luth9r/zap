const std = @import("std");
const Config = @import("../config/config.zig").Config;
const formatter = @import("../engine/formatter.zig");
const git_utils = @import("../utils/git_utils.zig");
const BufferWriter = @import("../utils/buffer_writer.zig").BufferWriter;

pub const PromptContext = @import("../engine/context.zig").PromptContext;

pub const GitStatusConfig = struct {
    // Format template for the git_status module.
    format: []const u8 = "[[$all_status$ahead_behind]]($style) ",
    // Style string for the status indicators.
    style: []const u8 = "bold red",
    // Symbol shown when changes are staged.
    staged: []const u8 = "+",
    // Symbol shown when files are modified.
    modified: []const u8 = "!",
    // Symbol shown when untracked files exist.
    untracked: []const u8 = "?",
    // Symbol shown when files are renamed.
    renamed: []const u8 = "»",
    // Symbol shown when files are deleted.
    deleted: []const u8 = "✘",
    // Symbol shown when stashed changes exist.
    stashed: []const u8 = "$",
    // Symbol shown when local branch is ahead of remote.
    ahead: []const u8 = "⇡",
    // Symbol shown when local branch is behind remote.
    behind: []const u8 = "⇣",
    // Symbol shown when branches have diverged.
    diverged: []const u8 = "⇕",
    // Symbol shown when merge conflicts exist.
    conflicted: []const u8 = "=",
    // Symbol shown when up to date with remote.
    up_to_date: []const u8 = "",
    // Whether the git_status module is disabled.
    disabled: bool = false,
};

/// Formats combined all_status string into a buffer.
pub fn formatAllStatus(
    buf: []u8,
    config: GitStatusConfig,
    info: git_utils.GitStatusInfo,
) []const u8 {
    var pos: usize = 0;
    const writer = BufferWriter.init(buf, &pos);

    const status_flags = comptime [_][]const u8{
        "conflicted",
        "stashed",
        "deleted",
        "renamed",
        "modified",
        "staged",
        "untracked",
    };

    // Comptime assertion: ensure every boolean status flag in GitStatusInfo is handled
    comptime {
        for (@typeInfo(git_utils.GitStatusInfo).@"struct".fields) |field| {
            if (field.type == bool) {
                var found = false;
                for (status_flags) |name| {
                    if (std.mem.eql(u8, name, field.name)) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    @compileError("Missing status flag in formatAllStatus: " ++ field.name);
                }
            }
        }
    }

    inline for (status_flags) |flag_name| {
        if (@field(info, flag_name)) {
            writer.writeAll(@field(config, flag_name)) catch {};
        }
    }

    return buf[0..pos];
}

/// Formats ahead/behind count string into a buffer.
pub fn formatAheadBehind(
    buf: []u8,
    config: GitStatusConfig,
    ahead: usize,
    behind: usize,
) []const u8 {
    if (ahead > 0 and behind > 0) {
        return std.fmt.bufPrint(buf, "{s}{d} {d}", .{ config.diverged, ahead, behind }) catch "";
    } else if (ahead > 0) {
        return std.fmt.bufPrint(buf, "{s}{d}", .{ config.ahead, ahead }) catch "";
    } else if (behind > 0) {
        return std.fmt.bufPrint(buf, "{s}{d}", .{ config.behind, behind }) catch "";
    }
    return "";
}

pub const is_git_dependent: bool = true;

/// Renders the git_status module according to configuration.
pub fn render(
    writer: anytype,
    config: GitStatusConfig,
    ctx: PromptContext,
) !void {
    if (config.disabled) return;
    const io = ctx.io orelse return;

    var git_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const git_dir = ctx.git_dir orelse git_utils.findGitDir(io, ctx.cwd, &git_dir_buf) orelse return;

    var head_buf: [512]u8 = undefined;
    const branch = git_utils.getGitBranchFromDir(io, git_dir, &head_buf);
    const info = git_utils.getGitStatusForDir(io, ctx.cwd, git_dir, branch);

    // If nothing to report and no status symbols, return early
    if (!info.hasAnyStatus()) return;

    var all_status_buf: [128]u8 = undefined;
    const all_status_str = formatAllStatus(&all_status_buf, config, info);

    var ahead_behind_buf: [64]u8 = undefined;
    const ahead_behind_str = formatAheadBehind(&ahead_behind_buf, config, info.ahead, info.behind);

    try formatter.formatTemplateWriter(writer, config.format, .{
        .style = config.style,
        .shell = ctx.shell,
        .vars = &[_]formatter.Variable{
            .{ .name = "all_status", .value = all_status_str },
            .{ .name = "ahead_behind", .value = ahead_behind_str },
            .{ .name = "stashed", .value = if (info.stashed) config.stashed else "" },
            .{ .name = "modified", .value = if (info.modified) config.modified else "" },
            .{ .name = "staged", .value = if (info.staged) config.staged else "" },
            .{ .name = "untracked", .value = if (info.untracked) config.untracked else "" },
            .{ .name = "renamed", .value = if (info.renamed) config.renamed else "" },
            .{ .name = "deleted", .value = if (info.deleted) config.deleted else "" },
        },
    });
}

test "formatAllStatus and formatAheadBehind" {
    const cfg = GitStatusConfig{};
    const info = git_utils.GitStatusInfo{
        .modified = true,
        .staged = true,
        .untracked = true,
        .stashed = true,
    };

    var buf: [128]u8 = undefined;
    const status_str = formatAllStatus(&buf, cfg, info);
    try std.testing.expectEqualStrings("$!+?", status_str);

    var ab_buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("⇡2", formatAheadBehind(&ab_buf, cfg, 2, 0));
    try std.testing.expectEqualStrings("⇣3", formatAheadBehind(&ab_buf, cfg, 0, 3));
    try std.testing.expectEqualStrings("⇕1 2", formatAheadBehind(&ab_buf, cfg, 1, 2));
}

test "formatAllStatus with conflicted, deleted, and renamed flags" {
    const cfg = GitStatusConfig{};
    const info = git_utils.GitStatusInfo{
        .conflicted = true,
        .deleted = true,
        .renamed = true,
        .modified = true,
        .staged = true,
        .untracked = true,
        .stashed = true,
    };

    var buf: [128]u8 = undefined;
    const status_str = formatAllStatus(&buf, cfg, info);

    try std.testing.expectEqualStrings("=$✘»!+?", status_str);
}

test "render git_status format with brackets and style" {
    var cfg = Config{};
    cfg.git_status.format = "[[$all_status$ahead_behind]]($style) ";
    cfg.git_status.style = "bold red";

    var buf: [256]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);

    // Directly test formatTemplateWriter with git_status variables
    try formatter.formatTemplateWriter(writer, cfg.git_status.format, .{
        .style = cfg.git_status.style,
        .vars = &[_]formatter.Variable{
            .{ .name = "all_status", .value = "!+" },
            .{ .name = "ahead_behind", .value = "⇡1" },
        },
    });

    const expected = "\x1b[1;31m[!+⇡1]\x1b[0m ";
    try std.testing.expectEqualStrings(expected, buf[0..pos]);
}

test "render git_status full symbols combination" {
    var cfg = Config{};
    cfg.git_status.format = "[[$all_status$ahead_behind]]($style) ";
    cfg.git_status.style = "bold red";

    var buf: [256]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);

    try formatter.formatTemplateWriter(writer, cfg.git_status.format, .{
        .style = cfg.git_status.style,
        .vars = &[_]formatter.Variable{
            .{ .name = "all_status", .value = "=$✘»!+?" },
            .{ .name = "ahead_behind", .value = "⇕2 1" },
        },
    });

    const expected = "\x1b[1;31m[=$✘»!+?⇕2 1]\x1b[0m ";
    try std.testing.expectEqualStrings(expected, buf[0..pos]);
}

test "render git_status disabled" {
    var cfg = GitStatusConfig{};
    cfg.disabled = true;

    var buf: [256]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);

    try render(writer, cfg, .{ .cwd = "/some/path", .home = "." });

    try std.testing.expectEqual(@as(usize, 0), pos);
}

test "integration: full git_status module rendering with custom symbols and all flags" {
    var cfg = GitStatusConfig{};
    cfg.format = "[[$all_status $ahead_behind]]($style) ";
    cfg.style = "bold red";
    cfg.conflicted = "=";
    cfg.stashed = "$";
    cfg.deleted = "✘";
    cfg.renamed = "»";
    cfg.modified = "!";
    cfg.staged = "+";
    cfg.untracked = "?";
    cfg.diverged = "⇕";
    cfg.ahead = "⇡";
    cfg.behind = "⇣";

    const info = git_utils.GitStatusInfo{
        .conflicted = true,
        .stashed = true,
        .deleted = true,
        .renamed = true,
        .modified = true,
        .staged = true,
        .untracked = true,
        .ahead = 4,
        .behind = 2,
    };

    var all_status_buf: [128]u8 = undefined;
    const all_status_str = formatAllStatus(&all_status_buf, cfg, info);
    try std.testing.expectEqualStrings("=$✘»!+?", all_status_str);

    var ahead_behind_buf: [64]u8 = undefined;
    const ahead_behind_str = formatAheadBehind(&ahead_behind_buf, cfg, info.ahead, info.behind);
    try std.testing.expectEqualStrings("⇕4 2", ahead_behind_str);

    var buf: [512]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);

    try formatter.formatTemplateWriter(writer, cfg.format, .{
        .style = cfg.style,
        .vars = &[_]formatter.Variable{
            .{ .name = "all_status", .value = all_status_str },
            .{ .name = "ahead_behind", .value = ahead_behind_str },
            .{ .name = "stashed", .value = if (info.stashed) cfg.stashed else "" },
            .{ .name = "modified", .value = if (info.modified) cfg.modified else "" },
            .{ .name = "staged", .value = if (info.staged) cfg.staged else "" },
            .{ .name = "untracked", .value = if (info.untracked) cfg.untracked else "" },
            .{ .name = "renamed", .value = if (info.renamed) cfg.renamed else "" },
            .{ .name = "deleted", .value = if (info.deleted) cfg.deleted else "" },
            .{ .name = "conflicted", .value = if (info.conflicted) cfg.conflicted else "" },
        },
    });

    const expected = "\x1b[1;31m[=$✘»!+? ⇕4 2]\x1b[0m ";
    try std.testing.expectEqualStrings(expected, buf[0..pos]);
}

test "integration: individual status variables in custom template" {
    var cfg = GitStatusConfig{};
    cfg.format = "(C:$conflicted )(S:$stashed )(M:$modified )(A:$staged )(U:$untracked )(R:$renamed )(D:$deleted )";

    var buf: [512]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);

    const info = git_utils.GitStatusInfo{
        .conflicted = true,
        .stashed = false,
        .modified = true,
        .staged = true,
        .untracked = true,
        .renamed = true,
        .deleted = true,
    };

    try formatter.formatTemplateWriter(writer, cfg.format, .{
        .vars = &[_]formatter.Variable{
            .{ .name = "conflicted", .value = if (info.conflicted) "=" else "" },
            .{ .name = "stashed", .value = if (info.stashed) "$" else "" },
            .{ .name = "modified", .value = if (info.modified) "!" else "" },
            .{ .name = "staged", .value = if (info.staged) "+" else "" },
            .{ .name = "untracked", .value = if (info.untracked) "?" else "" },
            .{ .name = "renamed", .value = if (info.renamed) "»" else "" },
            .{ .name = "deleted", .value = if (info.deleted) "✘" else "" },
        },
    });

    const expected = "C:= M:! A:+ U:? R:» D:✘ ";
    try std.testing.expectEqualStrings(expected, buf[0..pos]);
}

test "render git_status across all shells" {
    const Shell = @import("../init/root.zig").Shell;
    const assertValidShellAnsi = @import("../tests/fixture.zig").Fixture.assertValidShellAnsi;

    const cfg = GitStatusConfig{};
    var buf: [512]u8 = undefined;
    const shells = [_]Shell{ .bash, .zsh, .fish, .powershell };

    for (shells) |sh| {
        var pos: usize = 0;
        const writer = BufferWriter.init(&buf, &pos);
        try formatter.formatTemplateWriter(writer, cfg.format, .{
            .style = cfg.style,
            .shell = sh,
            .vars = &[_]formatter.Variable{
                .{ .name = "all_status", .value = "!?" },
                .{ .name = "ahead_behind", .value = "" },
            },
        });
        const out = buf[0..pos];
        try assertValidShellAnsi(out, sh);
    }

    // Exact string verification for Bash
    var pos_bash: usize = 0;
    try formatter.formatTemplateWriter(BufferWriter.init(&buf, &pos_bash), cfg.format, .{
        .style = cfg.style,
        .shell = .bash,
        .vars = &[_]formatter.Variable{
            .{ .name = "all_status", .value = "!?" },
            .{ .name = "ahead_behind", .value = "" },
        },
    });
    try std.testing.expectEqualStrings("\x01\x1b[1;31m\x02[!?]\x01\x1b[0m\x02 ", buf[0..pos_bash]);

    // Exact string verification for Zsh
    var pos_zsh: usize = 0;
    try formatter.formatTemplateWriter(BufferWriter.init(&buf, &pos_zsh), cfg.format, .{
        .style = cfg.style,
        .shell = .zsh,
        .vars = &[_]formatter.Variable{
            .{ .name = "all_status", .value = "!?" },
            .{ .name = "ahead_behind", .value = "" },
        },
    });
    try std.testing.expectEqualStrings("%{\x1b[1;31m%}[!?]%{\x1b[0m%} ", buf[0..pos_zsh]);
}

