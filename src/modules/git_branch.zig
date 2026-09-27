const std = @import("std");
const Config = @import("../config/config.zig").Config;
const formatter = @import("../engine/formatter.zig");
const git_utils = @import("../utils/git_utils.zig");

pub const GitBranchConfig = struct {
    // Format template for the git_branch module.
    format: []const u8 = "on [$symbol$branch]($style) ",
    // Symbol preceding the git branch name.
    symbol: []const u8 = " ",
    // Style string for the branch text.
    style: []const u8 = "bold purple",
    // Maximum character length for branch name before truncation (0 = disable).
    truncation_length: usize = 0,
    // Symbol appended when branch name is truncated.
    truncation_symbol: []const u8 = "…",
    // Whether the git_branch module is disabled.
    disabled: bool = false,
};

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
    config: Config,
    io: std.Io,
    cwd: []const u8,
) !void {
    if (config.git_branch.disabled) return;

    var git_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    var head_buf: [512]u8 = undefined;

    const raw_branch = git_utils.getGitBranch(io, cwd, &git_dir_buf, &head_buf) orelse return;

    var trunc_buf: [256]u8 = undefined;
    const branch_str = truncateBranch(
        &trunc_buf,
        raw_branch,
        config.git_branch.truncation_length,
        config.git_branch.truncation_symbol,
    );

    try formatter.formatTemplateWriter(writer, config.git_branch.format, .{
        .style = config.git_branch.style,
        .vars = &[_]formatter.Variable{
            .{ .name = "symbol", .value = config.git_branch.symbol },
            .{ .name = "branch", .value = branch_str },
        },
    });
}

test "truncateBranch below and above max_len" {
    var buf: [64]u8 = undefined;

    // Disabled (max_len = 0)
    try std.testing.expectEqualStrings("feature/authentication", truncateBranch(&buf, "feature/authentication", 0, "…"));

    // Below limit
    try std.testing.expectEqualStrings("main", truncateBranch(&buf, "main", 10, "…"));

    // Above limit
    try std.testing.expectEqualStrings("feat…", truncateBranch(&buf, "feature/auth", 4, "…"));
}

test "render git_branch disabled" {
    const BufferWriter = @import("../utils/buffer_writer.zig").BufferWriter;

    var cfg = Config{};
    cfg.git_branch.disabled = true;

    var buf: [256]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);

    // Should return immediately without any output or IO calls
    const mock_io: std.Io = undefined;
    try render(writer, cfg, mock_io, "/some/path");

    try std.testing.expectEqual(@as(usize, 0), pos);
}
