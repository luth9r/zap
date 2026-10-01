const std = @import("std");
const formatter = @import("../../../engine/formatter.zig");
const git_utils = @import("../../../utils/git_utils.zig");

pub const PromptContext = @import("../../../engine/context.zig").PromptContext;

pub const is_git_dependent: bool = true;

pub const Var = enum { branch, remote_branch, symbol };

pub const GitBranchConfig = struct {
    // Format template for the git_branch module.
    format: []const u8 = "on [$symbol$branch]($style) ",
    // Symbol preceding the git branch name.
    symbol: []const u8 = " ",
    // Style string for the branch text.
    style: []const u8 = "bold purple",
    // Maximum character length for branch name before truncation (0 = disable).
    truncation_length: usize = 0,
    // Symbol appended when branch name is truncated.
    truncation_symbol: []const u8 = "…",
    // Whether the git_branch module is disabled.
    disabled: bool = false,
};

pub const Config = GitBranchConfig;

/// Truncates a branch name if its length exceeds truncation_length.
pub fn truncateBranch(
    buf: []u8,
    branch: []const u8,
    max_len: usize,
    trunc_sym: []const u8,
) []const u8 {
    if (max_len == 0 or branch.len <= max_len) {
        return branch;
    }
    return std.fmt.bufPrint(buf, "{s}{s}", .{ branch[0..max_len], trunc_sym }) catch branch;
}

/// Renders the git_branch module according to configuration.
pub fn render(
    writer: anytype,
    config: GitBranchConfig,
    ctx: PromptContext,
) !void {
    if (config.disabled) return;
    const io = ctx.io orelse return;

    var git_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const git_dir = ctx.git_dir orelse git_utils.findGitDir(io, ctx.cwd, &git_dir_buf) orelse return;

    var head_buf: [512]u8 = undefined;
    const raw_branch = git_utils.getGitBranchFromDir(io, git_dir, &head_buf) orelse return;

    var trunc_buf: [256]u8 = undefined;
    const branch_str = truncateBranch(
        &trunc_buf,
        raw_branch,
        config.truncation_length,
        config.truncation_symbol,
    );

    try formatter.formatTemplateWriter(writer, config.format, formatter.FormatContext(Var){
        .style = config.style,
        .shell = ctx.shell,
        .vars = &.{
            .{ .name = .symbol, .value = config.symbol },
            .{ .name = .branch, .value = branch_str },
            .{ .name = .remote_branch, .value = "" },
        },
    });
}

pub const Harness = @import("../../../tests/harness.zig").Harness;

test "unit: truncateBranch below and above max_len" {
    var buf: [64]u8 = undefined;

    // Disabled (max_len = 0)
    try std.testing.expectEqualStrings("feature/authentication", truncateBranch(&buf, "feature/authentication", 0, "…"));

    // Below limit
    try std.testing.expectEqualStrings("main", truncateBranch(&buf, "main", 10, "…"));

    // Above limit
    try std.testing.expectEqualStrings("feat…", truncateBranch(&buf, "feature/auth", 4, "…"));
}

test "integration: git_branch shows current branch in repo" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.setupGit();
    try h.git(&.{ "checkout", "-b", "feature-super" });
    try h.setConfig(
        \\format = "$git_branch"
        \\add_newline = false
    );

    const out = try h.collectAllShells();
    try Harness.expectContains(out, "feature-super");
    try Harness.expectContains(out, "");
}

test "integration: git_branch with custom truncation" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.setupGit();
    try h.git(&.{ "checkout", "-b", "very-long-feature-branch" });
    try h.setConfig(
        \\format = "$git_branch"
        \\add_newline = false
        \\
        \\[git_branch]
        \\truncation_length = 4
        \\truncation_symbol = "…"
    );

    const out = try h.collectAllShells();
    try Harness.expectContains(out, "very…");
}

test "integration: git_branch disabled in config" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.setupGit();
    try h.setConfig(
        \\format = "$git_branch"
        \\add_newline = false
        \\
        \\[git_branch]
        \\disabled = true
    );

    const out = try h.collect(.generic);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "integration: git_branch outside git repo renders nothing" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.setConfig(
        \\format = "$git_branch"
        \\add_newline = false
    );

    const out = try h.collect(.generic);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "integration: git_branch in deep subdirectory" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.setupGit();
    try h.git(&.{ "checkout", "-b", "deep-branch" });
    _ = try h.setCwd("nested/deep/sub/dir");
    try h.setConfig(
        \\format = "$git_branch"
        \\add_newline = false
    );

    const out = try h.collectAllShells();
    try Harness.expectContains(out, "deep-branch");
}

test "integration: git_branch in git worktree" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.setupGit();
    const worktree_path = try std.fmt.allocPrint(h.arena.allocator(), "{s}/wt", .{h.tmp_dir});
    try h.git(&.{ "worktree", "add", "-b", "wt-branch", worktree_path });
    _ = try h.setCwd("wt");
    try h.setConfig(
        \\format = "$git_branch"
        \\add_newline = false
    );

    const out = try h.collectAllShells();
    try Harness.expectContains(out, "wt-branch");
}
