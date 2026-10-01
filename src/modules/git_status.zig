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

pub const Harness = @import("../tests/harness.zig").Harness;

test "integration: git_status renders nothing in clean repo" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.setupGit();
    try h.setConfig(
        \\format = "$git_status"
        \\add_newline = false
    );

    const out = try h.collect(.generic);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "integration: git_status with conflicted file shows =" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.setupGit();
    try h.writeFile("file.txt", "base");
    try h.git(&.{ "add", "." });
    try h.git(&.{ "commit", "-m", "base" });
    
    // Create branch a and modify
    try h.git(&.{ "checkout", "-b", "a" });
    try h.writeFile("file.txt", "a\n");
    try h.git(&.{ "add", "." });
    try h.git(&.{ "commit", "-m", "a" });
    
    // Create branch b and modify
    try h.git(&.{ "checkout", "master" });
    try h.git(&.{ "checkout", "-b", "b" });
    try h.writeFile("file.txt", "b\n");
    try h.git(&.{ "add", "." });
    try h.git(&.{ "commit", "-m", "b" });
    
    // Merge a into b causing conflict
    _ = try h.gitAllowFail(&.{ "merge", "a" });

    try h.setConfig(
        \\format = "$git_status"
        \\add_newline = false
    );

    const out = try h.collectAllShells();
    try Harness.expectVisibleText(out, "=");
}

test "integration: git_status with untracked file shows ?" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.setupGit();
    try h.writeFile("new_untracked_file.txt", "hello");
    try h.setConfig(
        \\format = "$git_status"
        \\add_newline = false
    );

    const out = try h.collectAllShells();
    try Harness.expectNotEmpty(out);
    try Harness.expectVisibleText(out, "?");
}

test "integration: git_status staged and modified flags" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.setupGit();
    try h.writeFile("tracked.txt", "v1");
    try h.git(&.{ "add", "tracked.txt" });
    try h.git(&.{ "commit", "-m", "add tracked" });

    // Modify tracked file (should show '!') and create untracked file (should show '?')
    try h.writeFile("tracked.txt", "v2 modified");
    try h.writeFile("untracked.txt", "new");

    try h.setConfig(
        \\format = "$git_status"
        \\add_newline = false
    );

    const out = try h.collectAllShells();
    try Harness.expectVisibleText(out, "!");
    try Harness.expectVisibleText(out, "?");
}

test "integration: git_status with custom symbols" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.setupGit();
    try h.writeFile("file.txt", "content");
    try h.setConfig(
        \\format = "$git_status"
        \\add_newline = false
        \\
        \\[git_status]
        \\untracked = "[UNTRACKED]"
    );

    const out = try h.collectAllShells();
    try Harness.expectVisibleText(out, "[UNTRACKED]");
}

test "integration: git_status disabled in config" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.setupGit();
    try h.writeFile("file.txt", "content");
    try h.setConfig(
        \\format = "$git_status"
        \\add_newline = false
        \\
        \\[git_status]
        \\disabled = true
    );

    const out = try h.collect(.generic);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "integration: git_status with deleted file shows deleted symbol" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.setupGit();
    try h.writeFile("to_delete.txt", "content");
    try h.git(&.{ "add", "to_delete.txt" });
    try h.git(&.{ "commit", "-m", "add to_delete" });
    try h.git(&.{ "rm", "to_delete.txt" });

    try h.setConfig(
        \\format = "$git_status"
        \\add_newline = false
    );

    const out = try h.collectAllShells();
    try Harness.expectVisibleText(out, "✘");
}

test "integration: git_status with renamed file shows renamed symbol" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.setupGit();
    try h.writeFile("original.txt", "content");
    try h.git(&.{ "add", "original.txt" });
    try h.git(&.{ "commit", "-m", "add original" });
    try h.git(&.{ "mv", "original.txt", "renamed.txt" });

    try h.setConfig(
        \\format = "$git_status"
        \\add_newline = false
    );

    const out = try h.collectAllShells();
    try Harness.expectVisibleText(out, "»");
}

test "integration: git_status with stashed changes shows stash symbol" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.setupGit();
    try h.writeFile("stash_target.txt", "v1");
    try h.git(&.{ "add", "stash_target.txt" });
    try h.git(&.{ "commit", "-m", "add stash_target" });
    try h.writeFile("stash_target.txt", "v2");
    try h.git(&.{ "stash" });

    try h.setConfig(
        \\format = "$git_status"
        \\add_newline = false
    );

    const out = try h.collectAllShells();
    try Harness.expectVisibleText(out, "$");
}

test "integration: git_status ahead of tracking branch shows ahead symbol" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.setupGit();
    try h.git(&.{ "commit", "--allow-empty", "-m", "base" });
    try h.git(&.{ "branch", "base_branch" });
    try h.git(&.{ "checkout", "-b", "feature" });
    try h.git(&.{ "branch", "--set-upstream-to=base_branch", "feature" });
    try h.git(&.{ "commit", "--allow-empty", "-m", "ahead" });

    try h.setConfig(
        \\format = "$git_status"
        \\add_newline = false
    );

    const out = try h.collectAllShells();
    try Harness.expectVisibleText(out, "⇡");
}

test "integration: git_status behind tracking branch shows behind symbol" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.setupGit();
    try h.git(&.{ "commit", "--allow-empty", "-m", "base" });
    try h.git(&.{ "branch", "base_branch" });
    try h.git(&.{ "checkout", "-b", "feature" });
    try h.git(&.{ "branch", "--set-upstream-to=base_branch", "feature" });
    try h.git(&.{ "checkout", "base_branch" });
    try h.git(&.{ "commit", "--allow-empty", "-m", "behind" });
    try h.git(&.{ "checkout", "feature" });

    try h.setConfig(
        \\format = "$git_status"
        \\add_newline = false
    );

    const out = try h.collectAllShells();
    try Harness.expectVisibleText(out, "⇣");
}

test "integration: git_status diverged from tracking branch shows diverged symbol" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.setupGit();
    try h.git(&.{ "commit", "--allow-empty", "-m", "base" });
    try h.git(&.{ "branch", "base_branch" });
    try h.git(&.{ "checkout", "-b", "feature" });
    try h.git(&.{ "branch", "--set-upstream-to=base_branch", "feature" });
    try h.git(&.{ "commit", "--allow-empty", "-m", "ahead" });
    try h.git(&.{ "checkout", "base_branch" });
    try h.git(&.{ "commit", "--allow-empty", "-m", "behind" });
    try h.git(&.{ "checkout", "feature" });

    try h.setConfig(
        \\format = "$git_status"
        \\add_newline = false
    );

    const out = try h.collectAllShells();
    try Harness.expectVisibleText(out, "⇕");
}
