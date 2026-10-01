const std = @import("std");
const formatter = @import("../engine/formatter.zig");
const git_utils = @import("../utils/git_utils.zig");

pub const PromptContext = @import("../engine/context.zig").PromptContext;

pub const is_git_dependent: bool = true;

pub const GitStateConfig = struct {
    // Format template for the git_state module.
    format: []const u8 = "\\([$state( $progress_current/$progress_total)]($style)\\) ",
    // Style string for the state text.
    style: []const u8 = "bold yellow",
    // Label shown when a rebase is in progress.
    rebase: []const u8 = "REBASING",
    // Label shown when a merge is in progress.
    merge: []const u8 = "MERGING",
    // Label shown when a revert is in progress.
    revert: []const u8 = "REVERTING",
    // Label shown when a cherry-pick is in progress.
    cherry_pick: []const u8 = "CHERRY-PICKING",
    // Label shown when a bisect is in progress.
    bisect: []const u8 = "BISECTING",
    // Label shown when applying mailbox patches.
    am: []const u8 = "AM",
    // Label shown when applying mailbox patches or rebasing.
    am_or_rebase: []const u8 = "AM/REBASE",
    // Whether the git_state module is disabled.
    disabled: bool = false,
};

/// Renders the git_state module according to configuration.
pub fn render(
    writer: anytype,
    config: GitStateConfig,
    ctx: PromptContext,
) !void {
    if (config.disabled) return;
    const io = ctx.io orelse return;

    var git_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const git_dir = ctx.git_dir orelse git_utils.findGitDir(io, ctx.cwd, &git_dir_buf) orelse return;

    var cur_buf: [32]u8 = undefined;
    var total_buf: [32]u8 = undefined;
    const state_res = git_utils.getGitState(io, git_dir, &cur_buf, &total_buf);

    const state_label = switch (state_res.state_type) {
        .none => return,
        .rebase => config.rebase,
        .merge => config.merge,
        .revert => config.revert,
        .cherry_pick => config.cherry_pick,
        .bisect => config.bisect,
        .am => config.am,
        .am_or_rebase => config.am_or_rebase,
    };

    try formatter.formatTemplateWriter(writer, config.format, .{
        .style = config.style,
        .shell = ctx.shell,
        .vars = &[_]formatter.Variable{
            .{ .name = "state", .value = state_label },
            .{ .name = "progress_current", .value = state_res.progress_current },
            .{ .name = "progress_total", .value = state_res.progress_total },
        },
    });
}

pub const Harness = @import("../tests/harness.zig").Harness;

test "integration: git_state renders nothing in normal clean repo" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.setupGit();
    try h.setConfig(
        \\format = "$git_state"
        \\add_newline = false
    );

    const out = try h.collect(.generic);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "integration: git_state during merge conflict" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.setupGit();
    try h.writeFile("conflict.txt", "base");
    try h.git(&.{ "add", "." });
    try h.git(&.{ "commit", "-m", "base" });

    try h.git(&.{ "checkout", "-b", "branch-a" });
    try h.writeFile("conflict.txt", "branch a version");
    try h.git(&.{ "add", "." });
    try h.git(&.{ "commit", "-m", "change in a" });

    try h.git(&.{ "checkout", "master" });
    try h.writeFile("conflict.txt", "branch main version");
    try h.git(&.{ "add", "." });
    try h.git(&.{ "commit", "-m", "change in main" });

    // Trigger merge conflict (git merge exits with non-zero on conflict)
    _ = try h.gitAllowFail(&.{ "merge", "branch-a" });

    try h.setConfig(
        \\format = "$git_state"
        \\add_newline = false
    );

    const out = try h.collectAllShells();
    try Harness.expectVisibleText(out, "MERGING");
}

test "integration: git_state disabled in config" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.setupGit();
    try h.setConfig(
        \\format = "$git_state"
        \\add_newline = false
        \\
        \\[git_state]
        \\disabled = true
    );

    const out = try h.collect(.generic);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "integration: git_state during rebase conflict" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.setupGit();
    try h.writeFile("conflict.txt", "base");
    try h.git(&.{ "add", "." });
    try h.git(&.{ "commit", "-m", "base" });

    try h.git(&.{ "checkout", "-b", "feature" });
    try h.writeFile("conflict.txt", "feature version");
    try h.git(&.{ "add", "." });
    try h.git(&.{ "commit", "-m", "feature change" });

    try h.git(&.{ "checkout", "master" });
    try h.writeFile("conflict.txt", "main version");
    try h.git(&.{ "add", "." });
    try h.git(&.{ "commit", "-m", "main change" });

    // Trigger rebase conflict
    _ = try h.gitAllowFail(&.{ "rebase", "feature" });

    try h.setConfig(
        \\format = "$git_state"
        \\add_newline = false
    );

    const out = try h.collectAllShells();
    try Harness.expectVisibleText(out, "REBASING");
}

test "integration: git_state during bisect" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.setupGit();
    try h.git(&.{ "bisect", "start" });

    try h.setConfig(
        \\format = "$git_state"
        \\add_newline = false
    );

    const out = try h.collectAllShells();
    try Harness.expectVisibleText(out, "BISECTING");
}

test "integration: git_state during cherry-pick" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.setupGit();
    try h.writeFile(".git/CHERRY_PICK_HEAD", "");

    try h.setConfig(
        \\format = "$git_state"
        \\add_newline = false
    );

    const out = try h.collectAllShells();
    try Harness.expectVisibleText(out, "CHERRY-PICKING");
}

test "integration: git_state during revert" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.setupGit();
    try h.writeFile(".git/REVERT_HEAD", "");

    try h.setConfig(
        \\format = "$git_state"
        \\add_newline = false
    );

    const out = try h.collectAllShells();
    try Harness.expectVisibleText(out, "REVERTING");
}

test "integration: git_state during am" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.setupGit();
    const rebase_apply = try std.fmt.allocPrint(h.arena.allocator(), "{s}/.git/rebase-apply", .{h.tmp_dir});
    try h.run(&[_][]const u8{ "mkdir", "-p", rebase_apply });
    try h.writeFile(".git/rebase-apply/applying", "");

    try h.setConfig(
        \\format = "$git_state"
        \\add_newline = false
    );

    const out = try h.collectAllShells();
    try Harness.expectVisibleText(out, "AM");
}

test "integration: git_state rebase progress" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.setupGit();
    const rebase_merge = try std.fmt.allocPrint(h.arena.allocator(), "{s}/.git/rebase-merge", .{h.tmp_dir});
    try h.run(&[_][]const u8{ "mkdir", "-p", rebase_merge });
    try h.writeFile(".git/rebase-merge/msgnum", "2");
    try h.writeFile(".git/rebase-merge/end", "5");

    try h.setConfig(
        \\format = "$git_state"
        \\add_newline = false
    );

    const out = try h.collectAllShells();
    try Harness.expectVisibleText(out, "REBASING 2/5");
}
