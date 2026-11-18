const std = @import("std");
const formatter = @import("../../../engine/formatter.zig");
const git_utils = @import("../../../utils/git_utils.zig");
const parse_utils = @import("../../../utils/parse_utils.zig");

pub const PromptContext = @import("../../../engine/context.zig").PromptContext;
pub const DebugContext = @import("../../../engine/context.zig").DebugContext;

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
    // Always populate $remote_branch even when it matches the local branch name.
    always_show_remote: bool = false,
    // Whether the git_branch module is disabled.
    disabled: bool = false,
};

pub const Config = GitBranchConfig;

/// Truncates a branch name by Unicode codepoint count (UTF-8 safe) if it exceeds max_len.
pub fn truncateBranch(
    buf: []u8,
    branch: []const u8,
    max_len: usize,
    trunc_sym: []const u8,
) []const u8 {
    if (max_len == 0 or branch.len <= max_len) {
        return branch;
    }

    var byte_idx: usize = 0;
    var char_count: usize = 0;
    while (byte_idx < branch.len) {
        if (char_count == max_len) break;
        const cp_len = std.unicode.utf8ByteSequenceLength(branch[byte_idx]) catch 1;
        if (byte_idx + cp_len > branch.len) break;
        byte_idx += cp_len;
        char_count += 1;
    }

    if (byte_idx >= branch.len) {
        return branch;
    }
    return std.fmt.bufPrint(buf, "{s}{s}", .{ branch[0..byte_idx], trunc_sym }) catch branch;
}

fn resolveRemoteBranch(
    io: std.Io,
    cwd: []const u8,
    git_dir: []const u8,
    config: GitBranchConfig,
    git_status: ?*const git_utils.GitStatusInfo,
    local_branch: []const u8,
    trunc_buf: *[256]u8,
) []const u8 {
    var fallback_status: git_utils.GitStatusInfo = .{};
    const status_ptr: *const git_utils.GitStatusInfo = git_status orelse blk: {
        if (std.mem.indexOf(u8, config.format, "$remote_branch") == null) return "";
        fallback_status = git_utils.getGitStatusForDir(io, cwd, git_dir);
        break :blk &fallback_status;
    };

    const merge_short = status_ptr.head.getRemoteBranch();
    if (merge_short.len == 0) return "";
    if (!config.always_show_remote and std.mem.eql(u8, merge_short, local_branch)) return "";

    return truncateBranch(trunc_buf, merge_short, config.truncation_length, config.truncation_symbol);
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
    const git_dir = ctx.getGitDir(io, &git_dir_buf) orelse return;

    var branch_buf: [256]u8 = undefined;
    const raw_branch = git_utils.resolveBranch(io, ctx.cwd, git_dir, ctx.git_status, &branch_buf) orelse return;

    var trunc_buf: [256]u8 = undefined;
    const branch_str = truncateBranch(&trunc_buf, raw_branch, config.truncation_length, config.truncation_symbol);

    var remote_trunc_buf: [256]u8 = undefined;
    const remote_branch_str = resolveRemoteBranch(io, ctx.cwd, git_dir, config, ctx.git_status, raw_branch, &remote_trunc_buf);

    try formatter.formatTemplateWriter(writer, config.format, formatter.FormatContext(Var){
        .style = config.style,
        .shell = ctx.shell,
        .vars = &.{
            .{ .name = .symbol, .value = config.symbol },
            .{ .name = .branch, .value = branch_str, .escape_shell = true },
            .{ .name = .remote_branch, .value = remote_branch_str, .escape_shell = true },
        },
    });
}

pub fn debug(writer: anytype, dctx: DebugContext) !void {
    const io = dctx.prompt.io orelse return;

    var git_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const git_dir = dctx.prompt.getGitDir(io, &git_dir_buf);

    var branch_buf: [256]u8 = undefined;
    const branch = if (git_dir) |gd|
        git_utils.resolveBranch(io, dctx.prompt.cwd, gd, dctx.prompt.git_status, &branch_buf)
    else
        null;

    if (dctx.json) {
        var j_gd: [std.fs.max_path_bytes]u8 = undefined;
        var j_br: [512]u8 = undefined;
        try writer.print(
            \\{{ "module": "git_branch", "git_dir": "{s}", "branch": "{s}" }}
            \\
        , .{
            parse_utils.escapeJsonBuf(&j_gd, git_dir orelse ""),
            parse_utils.escapeJsonBuf(&j_br, branch orelse ""),
        });
    } else {
        try writer.print(
            \\⚡ Module: git_branch
            \\  In Git Repo: {}
            \\  Git Dir:     {s}
            \\  Branch:      {s}
            \\
        , .{ git_dir != null, git_dir orelse "none", branch orelse "none" });
    }
}

const Harness = @import("../../../tests/harness.zig").Harness;

test "unit: truncateBranch below and above max_len" {
    var buf: [64]u8 = undefined;

    // Disabled (max_len = 0)
    try std.testing.expectEqualStrings("feature/authentication", truncateBranch(&buf, "feature/authentication", 0, "…"));

    // Below limit
    try std.testing.expectEqualStrings("main", truncateBranch(&buf, "main", 10, "…"));

    // Above limit
    try std.testing.expectEqualStrings("feat…", truncateBranch(&buf, "feature/auth", 4, "…"));

    // Multi-byte UTF-8 safe truncation (4 Cyrillic codepoints = 8 bytes)
    try std.testing.expectEqualStrings("ветк…", truncateBranch(&buf, "ветка-фичи", 4, "…"));
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

test "integration: git_branch with slashes and special characters" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.setupGit();
    try h.git(&.{ "checkout", "-b", "feature/auth-v2-@beta" });
    try h.setConfig(
        \\format = "$git_branch"
        \\add_newline = false
    );

    const out = try h.collectAllShells();
    try Harness.expectContains(out, "feature/auth-v2-@beta");
}
