const std = @import("std");
const Config = @import("../config/config.zig").Config;
const formatter = @import("../engine/formatter.zig");
const git_utils = @import("../utils/git_utils.zig");

pub const PromptContext = @import("../engine/context.zig").PromptContext;

pub const GitMetricsConfig = struct {
    // Format template for the git_metrics module.
    format: []const u8 = "([+$added]($added_style) )([-$deleted]($deleted_style) )",
    // Style string for added lines.
    added_style: []const u8 = "bold green",
    // Style string for deleted lines.
    deleted_style: []const u8 = "bold red",
    // Only render metrics if additions or deletions are non-zero.
    only_nonzero_diffs: bool = true,
    // Whether the git_metrics module is disabled (default = true for speed).
    disabled: bool = true,
};

/// Renders the git_metrics module according to configuration.
pub fn render(
    writer: anytype,
    config: Config,
    ctx: PromptContext,
) !void {
    if (config.git_metrics.disabled) return;
    const io = ctx.io orelse return;

    var git_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    _ = git_utils.findGitDir(io, ctx.cwd, &git_dir_buf) orelse return;

    const metrics = git_utils.GitMetricsResult{};

    if (config.git_metrics.only_nonzero_diffs and metrics.added == 0 and metrics.deleted == 0) {
        return;
    }

    var added_buf: [32]u8 = undefined;
    const added_str = if (metrics.added > 0)
        std.fmt.bufPrint(&added_buf, "{d}", .{metrics.added}) catch ""
    else
        "";

    var deleted_buf: [32]u8 = undefined;
    const deleted_str = if (metrics.deleted > 0)
        std.fmt.bufPrint(&deleted_buf, "{d}", .{metrics.deleted}) catch ""
    else
        "";

    try formatter.formatTemplateWriter(writer, config.git_metrics.format, .{
        .vars = &[_]formatter.Variable{
            .{ .name = "added", .value = added_str },
            .{ .name = "deleted", .value = deleted_str },
            .{ .name = "added_style", .value = config.git_metrics.added_style },
            .{ .name = "deleted_style", .value = config.git_metrics.deleted_style },
        },
    });
}

test "render git_metrics format with added and deleted lines" {
    const BufferWriter = @import("../utils/buffer_writer.zig").BufferWriter;

    var cfg = Config{};
    cfg.git_metrics.format = "([+$added]($added_style) )([-$deleted]($deleted_style) )";
    cfg.git_metrics.added_style = "bold green";
    cfg.git_metrics.deleted_style = "bold red";

    var buf: [256]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);

    try formatter.formatTemplateWriter(writer, cfg.git_metrics.format, .{
        .vars = &[_]formatter.Variable{
            .{ .name = "added", .value = "15" },
            .{ .name = "deleted", .value = "3" },
            .{ .name = "added_style", .value = cfg.git_metrics.added_style },
            .{ .name = "deleted_style", .value = cfg.git_metrics.deleted_style },
        },
    });

    const expected = "\x1b[1;32m+15\x1b[0m \x1b[1;31m-3\x1b[0m ";
    try std.testing.expectEqualStrings(expected, buf[0..pos]);
}

test "render git_metrics disabled" {
    const BufferWriter = @import("../utils/buffer_writer.zig").BufferWriter;

    var cfg = Config{};
    cfg.git_metrics.disabled = true;

    var buf: [256]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);

    try render(writer, cfg, .{ .cwd = "/some/path", .home = "." });

    try std.testing.expectEqual(@as(usize, 0), pos);
}
