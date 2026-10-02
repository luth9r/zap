const std = @import("std");
const formatter = @import("../../../engine/formatter.zig");
const git_utils = @import("../../../utils/git_utils.zig");
const BufferWriter = @import("../../../utils/buffer_writer.zig").BufferWriter;

pub const PromptContext = @import("../../../engine/context.zig").PromptContext;

pub const Var = enum { staged, stashed, modified, all_status, deleted, untracked, ahead_behind };

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

/// Formats a count template string by replacing `$count`, `$ahead`, and `$behind` placeholders.
fn formatCountTemplate(
    buf: []u8,
    template: []const u8,
    ahead: usize,
    behind: usize,
) []const u8 {
    var pos: usize = 0;
    const writer = BufferWriter.init(buf, &pos);
    var i: usize = 0;
    while (i < template.len) {
        if (std.mem.startsWith(u8, template[i..], "$ahead")) {
            writer.print("{d}", .{ahead}) catch {};
            i += "$ahead".len;
        } else if (std.mem.startsWith(u8, template[i..], "$behind")) {
            writer.print("{d}", .{behind}) catch {};
            i += "$behind".len;
        } else if (std.mem.startsWith(u8, template[i..], "$count")) {
            const count = if (ahead > 0) ahead else behind;
            writer.print("{d}", .{count}) catch {};
            i += "$count".len;
        } else {
            writer.writeByte(template[i]) catch {};
            i += 1;
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
        if (std.mem.indexOf(u8, config.diverged, "$ahead") != null or std.mem.indexOf(u8, config.diverged, "$behind") != null) {
            return formatCountTemplate(buf, config.diverged, ahead, behind);
        }
        return std.fmt.bufPrint(buf, "{s}{d} {d}", .{ config.diverged, ahead, behind }) catch "";
    } else if (ahead > 0) {
        if (std.mem.indexOf(u8, config.ahead, "$count") != null or std.mem.indexOf(u8, config.ahead, "$ahead") != null) {
            return formatCountTemplate(buf, config.ahead, ahead, 0);
        }
        return std.fmt.bufPrint(buf, "{s}{d}", .{ config.ahead, ahead }) catch "";
    } else if (behind > 0) {
        if (std.mem.indexOf(u8, config.behind, "$count") != null or std.mem.indexOf(u8, config.behind, "$behind") != null) {
            return formatCountTemplate(buf, config.behind, 0, behind);
        }
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

    // Custom diverged template with arrows
    const custom_cfg = GitStatusConfig{
        .diverged = "⇡$ahead⇣$behind",
    };
    try std.testing.expectEqualStrings("⇡1⇣2", formatAheadBehind(&ab_buf, custom_cfg, 1, 2));
}

test "unit: formatAllStatus with conflicted, deleted flags" {
    const cfg = GitStatusConfig{};
    const info = git_utils.GitStatusInfo{
        .conflicted = true,
        .deleted = true,
        .modified = true,
        .staged = true,
        .untracked = true,
        .stashed = true,
    };

    var buf: [128]u8 = undefined;
    const status_str = formatAllStatus(&buf, cfg, info);

    try std.testing.expectEqualStrings("=$✘!+?", status_str);
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
    try h.deleteFile("to_delete.txt");

    try h.setConfig(
        \\format = "$git_status"
        \\add_newline = false
    );

    const out = try h.collectAllShells();
    try Harness.expectVisibleText(out, "✘");
}

test "integration: git_status with renamed file shows staged symbol" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.setupGit();
    try h.writeFile("original.txt", "content");
    try h.git(&.{ "add", "original.txt" });
    try h.git(&.{ "commit", "-m", "add original" });
    try h.git(&.{ "mv", "original.txt", "modified.txt" });

    try h.setConfig(
        \\format = "$git_status"
        \\add_newline = false
    );

    const out = try h.collectAllShells();
    try Harness.expectVisibleText(out, "+");
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

    // 3. Rename a file (staged: +)
    try h.git(&.{ "mv", "orig_renamed.txt", "renamed.txt" });

    // 4. Delete a file (deleted: ✘)
    try h.deleteFile("to_delete.txt");

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

test "integration: git_status detects untracked file in deep subdirectory" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.setupGit();
    try h.writeFile("src/main.zig", "pub fn main() {}");
    try h.git(&.{ "add", "." });
    try h.git(&.{ "commit", "-m", "init" });

    // Add untracked file inside existing tracked directory src/
    try h.writeFile("src/nested_untracked.zig", "const x = 1;");

    try h.setConfig(
        \\format = "$git_status"
        \\add_newline = false
    );

    const out = try h.collectAllShells();
    try Harness.expectVisibleText(out, "?");
}

test "integration: git_status detects untracked file 4 levels deep in tracked tree" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.setupGit();
    try h.writeFile("a/b/c/tracked.zig", "pub fn main() {}");
    try h.git(&.{ "add", "." });
    try h.git(&.{ "commit", "-m", "init" });

    // Add untracked file inside deeply nested directory a/b/c/d/deep.txt
    try h.writeFile("a/b/c/d/deep.txt", "deep untracked content");

    try h.setConfig(
        \\format = "$git_status"
        \\add_newline = false
    );

    const out = try h.collectAllShells();
    try Harness.expectVisibleText(out, "?");
}

test "integration: git_status stress test with 500+ files and nested directory tree" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.setupGit();

    // Create 500 files across 10 subdirectories
    var dir_idx: usize = 0;
    while (dir_idx < 10) : (dir_idx += 1) {
        var file_idx: usize = 0;
        while (file_idx < 50) : (file_idx += 1) {
            var path_buf: [64]u8 = undefined;
            const path = try std.fmt.bufPrint(&path_buf, "dir{d}/file_{d}.txt", .{ dir_idx, file_idx });
            try h.writeFile(path, "content");
        }
    }

    try h.git(&.{ "add", "." });
    try h.git(&.{ "commit", "-m", "large repo commit" });

    // 1. Stage a new file (+)
    try h.writeFile("dir0/staged.txt", "staged_content");
    try h.git(&.{ "add", "dir0/staged.txt" });

    // 2. Modify an existing tracked file (!)
    try h.writeFile("dir1/file_0.txt", "modified_content");

    // 3. Delete an existing tracked file (✘)
    try h.deleteFile("dir2/file_0.txt");

    // 4. Add an untracked file in a nested directory (?)
    try h.writeFile("dir3/untracked_nested.txt", "untracked_content");

    try h.setConfig(
        \\format = "$git_status"
        \\add_newline = false
    );

    const out = try h.collectAllShells();
    try Harness.expectVisibleText(out, "+");
    try Harness.expectVisibleText(out, "!");
    try Harness.expectVisibleText(out, "✘");
    try Harness.expectVisibleText(out, "?");
}

test "integration: git_status ahead count with large reflog exceeding buffer limit" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.setupGit();

    // Generate 50 commits to make reflog file grow past 6-8 KB
    var c_idx: usize = 0;
    while (c_idx < 50) : (c_idx += 1) {
        var msg_buf: [64]u8 = undefined;
        const msg = try std.fmt.bufPrint(&msg_buf, "historical commit number {d}", .{c_idx});
        try h.git(&.{ "commit", "--allow-empty", "-m", msg });
    }

    // Set upstream tracking branch at current historical commit
    try h.git(&.{ "branch", "origin_master" });
    try h.git(&.{ "branch", "--set-upstream-to=origin_master", "master" });

    // Make 5 new commits ahead of upstream
    var ahead_idx: usize = 0;
    while (ahead_idx < 5) : (ahead_idx += 1) {
        var msg_buf: [64]u8 = undefined;
        const msg = try std.fmt.bufPrint(&msg_buf, "new ahead commit {d}", .{ahead_idx});
        try h.git(&.{ "commit", "--allow-empty", "-m", msg });
    }

    try h.setConfig(
        \\format = "$git_status"
        \\add_newline = false
    );

    const out = try h.collectAllShells();
    // Must display ahead 5 (⇡5), and must NOT false-report diverged (⇕)
    try Harness.expectVisibleText(out, "⇡5");
    try Harness.expectNotContains(out, "⇕");
}

test "integration: git_status complex stress scenario with multi-directory modifications, staging, deletions, untracked, ignore rules, stash and ahead" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.setupGit();

    // 1. Setup .gitignore with multiple pattern types
    try h.writeFile(".gitignore", "*.log\ntemp/\nbuild/\n*.tmp\n");

    // 2. Create 200 tracked files across 10 subdirectories
    var dir_idx: usize = 0;
    while (dir_idx < 10) : (dir_idx += 1) {
        var file_idx: usize = 0;
        while (file_idx < 20) : (file_idx += 1) {
            var path_buf: [64]u8 = undefined;
            const path = try std.fmt.bufPrint(&path_buf, "dir{d}/file_{d}.txt", .{ dir_idx, file_idx });
            try h.writeFile(path, "initial content");
        }
    }
    try h.git(&.{ "add", "." });
    try h.git(&.{ "commit", "-m", "initial commit of 200 files" });

    // 3. Set upstream tracking branch and add ahead commits
    try h.git(&.{ "branch", "origin_main" });
    try h.git(&.{ "branch", "--set-upstream-to=origin_main", "master" });
    try h.git(&.{ "commit", "--allow-empty", "-m", "ahead commit 1" });
    try h.git(&.{ "commit", "--allow-empty", "-m", "ahead commit 2" });
    try h.git(&.{ "commit", "--allow-empty", "-m", "ahead commit 3" });

    // 4. Stash a change ($)
    try h.writeFile("dir0/file_0.txt", "stash candidate");
    try h.git(&.{"stash"});

    // 5. Create multiple ignored files and directories (must NOT trigger untracked flag '?')
    try h.writeFile("dir0/debug.log", "some log info");
    try h.writeFile("dir1/cache.tmp", "temp data");
    try h.writeFile("temp/nested_temp.txt", "ignored temp file");
    try h.writeFile("build/output.bin", "binary data");

    // 6. Stage multiple modifications and newly added files (+)
    try h.writeFile("dir2/file_1.txt", "staged modified content 1");
    try h.writeFile("dir3/file_2.txt", "staged modified content 2");
    try h.writeFile("dir4/newly_staged.txt", "brand new staged file");
    try h.git(&.{ "add", "dir2/file_1.txt", "dir3/file_2.txt", "dir4/newly_staged.txt" });

    // 7. Modify multiple tracked unstaged files (!)
    try h.writeFile("dir5/file_3.txt", "unstaged modification A");
    try h.writeFile("dir6/file_4.txt", "unstaged modification B");

    // 8. Delete multiple tracked files (✘)
    try h.deleteFile("dir7/file_5.txt");
    try h.deleteFile("dir8/file_6.txt");

    // 9. Add multiple real untracked files across different folders (?)
    try h.writeFile("dir9/real_untracked_1.txt", "untracked 1");
    try h.writeFile("dir0/real_untracked_2.txt", "untracked 2");
    try h.writeFile("root_untracked.txt", "root untracked");

    try h.setConfig(
        \\format = "$git_status"
        \\add_newline = false
    );

    const out = try h.collectAllShells();
    try Harness.expectVisibleText(out, "$"); // stash
    try Harness.expectVisibleText(out, "✘"); // deleted
    try Harness.expectVisibleText(out, "!"); // modified
    try Harness.expectVisibleText(out, "+"); // staged
    try Harness.expectVisibleText(out, "?"); // untracked
    try Harness.expectVisibleText(out, "⇡3"); // ahead 3
}

test "integration: git_status complex diverged counts with large commit histories and dirty index" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.setupGit();

    // 1. Initial base commit
    try h.writeFile("base.txt", "base");
    try h.git(&.{ "add", "." });
    try h.git(&.{ "commit", "-m", "base" });

    // 2. Create upstream branch and add 4 behind commits
    try h.git(&.{ "checkout", "-b", "upstream_branch" });
    var behind_idx: usize = 0;
    while (behind_idx < 4) : (behind_idx += 1) {
        var msg_buf: [64]u8 = undefined;
        const msg = try std.fmt.bufPrint(&msg_buf, "behind commit {d}", .{behind_idx});
        try h.git(&.{ "commit", "--allow-empty", "-m", msg });
    }

    // 3. Switch back to master, branch out to feature, and add 7 ahead commits
    try h.git(&.{ "checkout", "master" });
    try h.git(&.{ "checkout", "-b", "feature_branch" });
    try h.git(&.{ "branch", "--set-upstream-to=upstream_branch", "feature_branch" });

    var ahead_idx: usize = 0;
    while (ahead_idx < 7) : (ahead_idx += 1) {
        var msg_buf: [64]u8 = undefined;
        const msg = try std.fmt.bufPrint(&msg_buf, "ahead commit {d}", .{ahead_idx});
        try h.git(&.{ "commit", "--allow-empty", "-m", msg });
    }

    // 4. Populate with 50 files and make working directory dirty
    var f_idx: usize = 0;
    while (f_idx < 50) : (f_idx += 1) {
        var path_buf: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "pkg/file_{d}.txt", .{f_idx});
        try h.writeFile(path, "tracked content");
    }
    try h.git(&.{ "add", "." });
    try h.git(&.{ "commit", "-m", "add 50 files" });

    // Now feature has 8 ahead commits and 4 behind
    // Create dirty state (modified + untracked + staged)
    try h.writeFile("pkg/file_0.txt", "modified content");
    try h.writeFile("pkg/new_file.txt", "staged new file");
    try h.git(&.{ "add", "pkg/new_file.txt" });
    try h.writeFile("untracked_probe.txt", "untracked");

    try h.setConfig(
        \\format = "$git_status"
        \\add_newline = false
    );

    const out = try h.collectAllShells();
    try Harness.expectVisibleText(out, "⇕8 4");
    try Harness.expectVisibleText(out, "!");
    try Harness.expectVisibleText(out, "+");
    try Harness.expectVisibleText(out, "?");
}

test "integration: git_status diverged custom template with arrows" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.setupGit();
    try h.git(&.{ "commit", "--allow-empty", "-m", "base" });
    try h.git(&.{ "branch", "upstream_branch" });
    try h.git(&.{ "checkout", "-b", "feature" });
    try h.git(&.{ "branch", "--set-upstream-to=upstream_branch", "feature" });
    try h.git(&.{ "commit", "--allow-empty", "-m", "ahead 1" });
    try h.git(&.{ "commit", "--allow-empty", "-m", "ahead 2" });
    try h.git(&.{ "checkout", "upstream_branch" });
    try h.git(&.{ "commit", "--allow-empty", "-m", "behind 1" });
    try h.git(&.{ "commit", "--allow-empty", "-m", "behind 2" });
    try h.git(&.{ "commit", "--allow-empty", "-m", "behind 3" });
    try h.git(&.{ "checkout", "feature" });

    try h.setConfig(
        \\format = "$git_status"
        \\add_newline = false
        \\
        \\[git_status]
        \\diverged = "⇡$ahead⇣$behind"
    );

    const out = try h.collectAllShells();
    try Harness.expectVisibleText(out, "⇡2⇣3");
}

test "integration: git_status deep nested directories with partial ignores and untracked files" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.setupGit();

    // 1. Setup gitignore with deep pattern
    try h.writeFile(".gitignore", "src/**/ignored_*\n*.bak\n");

    // 2. Create 5-level deep directory tree
    try h.writeFile("src/level1/level2/level3/level4/tracked.zig", "const x = 42;");
    try h.writeFile("src/level1/level2/tracked_mid.zig", "const y = 10;");
    try h.git(&.{ "add", "." });
    try h.git(&.{ "commit", "-m", "deep tree init" });

    // 3. Create ignored files in deep directories
    try h.writeFile("src/level1/level2/level3/level4/ignored_cache.tmp", "ignored");
    try h.writeFile("src/level1/ignored_data.txt", "ignored");
    try h.writeFile("src/backup.bak", "ignored backup");

    // 4. Create real untracked files in deep directories
    try h.writeFile("src/level1/level2/level3/level4/new_deep.zig", "const z = 100;");

    // 5. Modify tracked deep file
    try h.writeFile("src/level1/level2/tracked_mid.zig", "const y = 20; // modified");

    try h.setConfig(
        \\format = "$git_status"
        \\add_newline = false
    );

    const out = try h.collectAllShells();
    try Harness.expectVisibleText(out, "!");
    try Harness.expectVisibleText(out, "?");
}

test "integration: git_status in git worktree" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.setupGit();
    try h.writeFile("main.txt", "v1");
    try h.git(&.{ "add", "." });
    try h.git(&.{ "commit", "-m", "init" });

    // Create a git worktree
    const wt_path = try std.fmt.allocPrint(h.arena.allocator(), "{s}/wt", .{h.tmp_dir});
    try h.git(&.{ "worktree", "add", "-b", "wt_branch", wt_path });

    // Switch cwd to worktree and make changes
    _ = try h.setCwd("wt");
    try h.writeFile("wt/worktree_file.txt", "new worktree content");
    try h.git(&.{ "-C", wt_path, "add", "worktree_file.txt" });
    try h.writeFile("wt/untracked.txt", "untracked");

    try h.setConfig(
        \\format = "$git_branch $git_status"
        \\add_newline = false
    );

    const out = try h.collectAllShells();
    try Harness.expectVisibleText(out, "wt_branch");
    try Harness.expectVisibleText(out, "+");
    try Harness.expectVisibleText(out, "?");
}

test "integration: git_status with packed-refs after git gc" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.setupGit();
    try h.writeFile("file.txt", "base");
    try h.git(&.{ "add", "." });
    try h.git(&.{ "commit", "-m", "base commit" });

    // Upstream tracking branch
    try h.git(&.{ "branch", "origin_main" });
    try h.git(&.{ "branch", "--set-upstream-to=origin_main", "master" });

    // Add 2 ahead commits
    try h.git(&.{ "commit", "--allow-empty", "-m", "ahead 1" });
    try h.git(&.{ "commit", "--allow-empty", "-m", "ahead 2" });

    // Run git gc to pack all loose refs into .git/packed-refs
    try h.git(&.{"gc"});

    // Make a dirty working copy
    try h.writeFile("file.txt", "modified after gc");

    try h.setConfig(
        \\format = "$git_status"
        \\add_newline = false
    );

    const out = try h.collectAllShells();
    try Harness.expectVisibleText(out, "!");
    try Harness.expectVisibleText(out, "⇡2");
}

test "integration: git_status in detached HEAD state" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.setupGit();
    try h.writeFile("file.txt", "v1");
    try h.git(&.{ "add", "." });
    try h.git(&.{ "commit", "-m", "commit 1" });

    try h.writeFile("file.txt", "v2");
    try h.git(&.{ "add", "." });
    try h.git(&.{ "commit", "-m", "commit 2" });

    // Detach HEAD to first commit
    try h.git(&.{ "checkout", "HEAD~1" });

    // Make local modifications
    try h.writeFile("detached_new.txt", "untracked");

    try h.setConfig(
        \\format = "$git_status"
        \\add_newline = false
    );

    const out = try h.collectAllShells();
    try Harness.expectVisibleText(out, "?");
}

test "integration: git_status staged deletions and additions combined" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.setupGit();
    try h.writeFile("keep.txt", "keep");
    try h.writeFile("to_remove.txt", "delete me");
    try h.git(&.{ "add", "." });
    try h.git(&.{ "commit", "-m", "init" });

    // 1. Staged deletion (git rm)
    try h.git(&.{ "rm", "to_remove.txt" });

    // 2. Staged addition (new file)
    try h.writeFile("brand_new.txt", "new");
    try h.git(&.{ "add", "brand_new.txt" });

    // 3. Unstaged modification
    try h.writeFile("keep.txt", "keep modified");

    // 4. Untracked file
    try h.writeFile("untracked.txt", "untracked");

    try h.setConfig(
        \\format = "$git_status"
        \\add_newline = false
    );

    const out = try h.collectAllShells();
    try Harness.expectVisibleText(out, "+"); // staged (addition or deletion)
    try Harness.expectVisibleText(out, "!"); // modified
    try Harness.expectVisibleText(out, "?"); // untracked
}

test "integration: git_status massive repo stress test with 1000 files across 20 directories" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.setupGit();

    // Generate 1000 files across 20 subdirectories
    var dir_idx: usize = 0;
    while (dir_idx < 20) : (dir_idx += 1) {
        var file_idx: usize = 0;
        while (file_idx < 50) : (file_idx += 1) {
            var path_buf: [64]u8 = undefined;
            const path = try std.fmt.bufPrint(&path_buf, "sub_{d}/f_{d}.zig", .{ dir_idx, file_idx });
            try h.writeFile(path, "const val = 123;");
        }
    }

    try h.git(&.{ "add", "." });
    try h.git(&.{ "commit", "-m", "1000 files commit" });

    // Make modifications across several directories
    try h.writeFile("sub_0/f_0.zig", "const val = 999;"); // unstaged modified (!)
    try h.writeFile("sub_5/new_staged.zig", "const staged = true;");
    try h.git(&.{ "add", "sub_5/new_staged.zig" }); // staged (+)
    try h.deleteFile("sub_10/f_5.zig"); // unstaged deleted (✘)
    try h.writeFile("sub_15/untracked_nested.zig", "const un = true;"); // untracked (?)

    try h.setConfig(
        \\format = "$git_status"
        \\add_newline = false
    );

    const out = try h.collectAllShells();
    try Harness.expectVisibleText(out, "+");
    try Harness.expectVisibleText(out, "!");
    try Harness.expectVisibleText(out, "✘");
    try Harness.expectVisibleText(out, "?");
}



