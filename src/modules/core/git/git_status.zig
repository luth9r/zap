const std = @import("std");
const formatter = @import("../../../engine/formatter.zig");
const git_utils = @import("../../../utils/git_utils.zig");
const BufferWriter = @import("../../../utils/buffer_writer.zig").BufferWriter;

pub const PromptContext = @import("../../../engine/context.zig").PromptContext;

pub const Var = enum { staged, stashed, modified, all_status, deleted, untracked, renamed, ahead_behind };

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

pub const Config = GitStatusConfig;

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

    try formatter.formatTemplateWriter(writer, config.format, formatter.FormatContext(Var){
        .style = config.style,
        .shell = ctx.shell,
        .vars = &.{
            .{ .name = .all_status, .value = all_status_str },
            .{ .name = .ahead_behind, .value = ahead_behind_str },
            .{ .name = .stashed, .value = if (info.stashed) config.stashed else "" },
            .{ .name = .modified, .value = if (info.modified) config.modified else "" },
            .{ .name = .staged, .value = if (info.staged) config.staged else "" },
            .{ .name = .untracked, .value = if (info.untracked) config.untracked else "" },
            .{ .name = .renamed, .value = if (info.renamed) config.renamed else "" },
            .{ .name = .deleted, .value = if (info.deleted) config.deleted else "" },
        },
    });
}

test "unit: formatAllStatus and formatAheadBehind" {
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

test "unit: formatAllStatus with conflicted, deleted, and renamed flags" {
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

pub const Harness = @import("../../../tests/harness.zig").Harness;

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
    try h.git(&.{"stash"});

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

test "integration: git_status ignores files listed in .gitignore" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.setupGit();
    try h.writeFile(".gitignore", "config.toml\nignored_folder/\n*.log\n");
    try h.git(&.{ "add", ".gitignore" });
    try h.git(&.{ "commit", "-m", "add gitignore" });

    // Create ignored files/folders and an untracked file
    try h.writeFile("app.log", "some log text");
    const ign_dir = try std.fmt.allocPrint(h.arena.allocator(), "{s}/ignored_folder", .{h.tmp_dir});
    try h.run(&[_][]const u8{ "mkdir", "-p", ign_dir });
    try h.writeFile("ignored_folder/cache.bin", "cached data");

    try h.setConfig(
        \\format = "$git_status"
        \\add_newline = false
    );

    // Should render empty because only ignored files exist
    const out_clean = try h.collect(.generic);
    try std.testing.expectEqual(@as(usize, 0), out_clean.len);

    // Now create a real untracked file
    try h.writeFile("real_untracked.txt", "untracked data");
    const out_untracked = try h.collectAllShells();
    try Harness.expectVisibleText(out_untracked, "?");
}

test "integration: git_status combined multiple flags simultaneously" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.setupGit();
    try h.writeFile("staged.txt", "v1");
    try h.writeFile("modified.txt", "v1");
    try h.writeFile("stash.txt", "v1");
    try h.writeFile("orig_renamed.txt", "v1");
    try h.writeFile("to_delete.txt", "v1");
    try h.git(&.{ "add", "." });
    try h.git(&.{ "commit", "-m", "init" });

    // 1. Set upstream and make an ahead commit (ahead: ⇡1)
    try h.git(&.{ "branch", "upstream_branch" });
    try h.git(&.{ "branch", "--set-upstream-to=upstream_branch", "master" });
    try h.git(&.{ "commit", "--allow-empty", "-m", "ahead_commit" });

    // 2. Stash a change (stashed: $)
    try h.writeFile("stash.txt", "v2");
    try h.git(&.{"stash"});

    // 3. Rename a file (renamed: »)
    try h.git(&.{ "mv", "orig_renamed.txt", "renamed.txt" });

    // 4. Delete a file (deleted: ✘)
    try h.git(&.{ "rm", "to_delete.txt" });

    // 5. Stage a file (staged: +)
    try h.writeFile("staged.txt", "staged_v2");
    try h.git(&.{ "add", "staged.txt" });

    // 6. Modify an unstaged file (modified: !)
    try h.writeFile("modified.txt", "modified_v2");

    // 7. Untracked file (untracked: ?)
    try h.writeFile("untracked.txt", "untracked_new");

    try h.setConfig(
        \\format = "$git_status"
        \\add_newline = false
    );

    const out = try h.collectAllShells();
    try Harness.expectVisibleText(out, "$"); // stashed
    try Harness.expectVisibleText(out, "✘"); // deleted
    try Harness.expectVisibleText(out, "»"); // renamed
    try Harness.expectVisibleText(out, "!"); // modified
    try Harness.expectVisibleText(out, "+"); // staged
    try Harness.expectVisibleText(out, "?"); // untracked
    try Harness.expectVisibleText(out, "⇡1"); // ahead
}

test "integration: git_status custom format with individual variable tokens" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.setupGit();
    try h.writeFile("f1.txt", "v1");
    try h.writeFile("f2.txt", "v1");
    try h.git(&.{ "add", "." });
    try h.git(&.{ "commit", "-m", "init" });

    // Stage f1 and modify f2
    try h.writeFile("f1.txt", "v2");
    try h.git(&.{ "add", "f1.txt" });
    try h.writeFile("f2.txt", "v2");

    try h.setConfig(
        \\format = "$git_status"
        \\add_newline = false
        \\
        \\[git_status]
        \\format = "staged:[$staged] modified:[$modified] "
    );

    const out = try h.collectAllShells();
    try Harness.expectVisibleText(out, "staged:[+]");
    try Harness.expectVisibleText(out, "modified:[!]");
}

test "integration: git_status conflicted and diverged with custom symbols" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.setupGit();
    try h.writeFile("file.txt", "base");
    try h.git(&.{ "add", "." });
    try h.git(&.{ "commit", "-m", "base" });

    // Branch a with change
    try h.git(&.{ "checkout", "-b", "branch_a" });
    try h.writeFile("file.txt", "version A");
    try h.git(&.{ "add", "." });
    try h.git(&.{ "commit", "-m", "commit A" });

    // Master branch with conflicting change and upstream tracking
    try h.git(&.{ "checkout", "master" });
    try h.writeFile("file.txt", "version B");
    try h.git(&.{ "add", "." });
    try h.git(&.{ "commit", "-m", "commit B" });

    // Merge branch_a into master causing conflict
    _ = try h.gitAllowFail(&.{ "merge", "branch_a" });

    try h.setConfig(
        \\format = "$git_status"
        \\add_newline = false
        \\
        \\[git_status]
        \\conflicted = "[CONFLICT]"
        \\style = "bold red"
    );

    const out = try h.collectAllShells();
    try Harness.expectVisibleText(out, "[CONFLICT]");
}



