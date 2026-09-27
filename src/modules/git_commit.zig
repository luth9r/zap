const std = @import("std");
const Config = @import("../config/config.zig").Config;
const formatter = @import("../engine/formatter.zig");
const git_utils = @import("../utils/git_utils.zig");

pub const PromptContext = @import("../engine/context.zig").PromptContext;

pub const GitCommitConfig = struct {
    // Format template for the git_commit module.
    format: []const u8 = "[\\($hash$tag\\)]($style) ",
    // Style string for the commit hash and tag.
    style: []const u8 = "bold green",
    // Number of characters to display from the commit hash (0 = full SHA).
    commit_hash_length: usize = 7,
    // Only display git_commit when HEAD is detached.
    only_detached: bool = true,
    // Symbol preceding tag name.
    tag_symbol: []const u8 = "  ",
    // Whether to disable tag display.
    tag_disabled: bool = true,
    // Whether the git_commit module is disabled.
    disabled: bool = false,
};

/// Renders the git_commit module according to configuration.
pub fn render(
    writer: anytype,
    config: Config,
    ctx: PromptContext,
) !void {
    if (config.git_commit.disabled) return;
    const io = ctx.io orelse return;

    var git_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const git_dir = git_utils.findGitDir(io, ctx.cwd, &git_dir_buf) orelse return;

    var head_buf: [512]u8 = undefined;
    var ref_buf: [512]u8 = undefined;
    const commit_info = git_utils.getGitCommit(io, git_dir, &head_buf, &ref_buf) orelse return;

    if (config.git_commit.only_detached and !commit_info.is_detached) {
        return;
    }

    if (commit_info.hash.len == 0) return;

    var short_hash = commit_info.hash;
    const hash_len = config.git_commit.commit_hash_length;
    if (hash_len > 0 and short_hash.len > hash_len) {
        short_hash = short_hash[0..hash_len];
    }

    var tag_buf: [256]u8 = undefined;
    var tag_str: []const u8 = "";
    if (!config.git_commit.tag_disabled and commit_info.tag.len > 0) {
        tag_str = std.fmt.bufPrint(&tag_buf, "{s}{s}", .{ config.git_commit.tag_symbol, commit_info.tag }) catch "";
    }

    try formatter.formatTemplateWriter(writer, config.git_commit.format, .{
        .style = config.git_commit.style,
        .vars = &[_]formatter.Variable{
            .{ .name = "hash", .value = short_hash },
            .{ .name = "tag", .value = tag_str },
        },
    });
}

test "render git_commit detached hash format" {
    const BufferWriter = @import("../utils/buffer_writer.zig").BufferWriter;

    var cfg = Config{};
    cfg.git_commit.format = "[\\($hash\\)]($style) ";
    cfg.git_commit.style = "bold green";

    var buf: [256]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);

    try formatter.formatTemplateWriter(writer, cfg.git_commit.format, .{
        .style = cfg.git_commit.style,
        .vars = &[_]formatter.Variable{
            .{ .name = "hash", .value = "4cd65cc" },
            .{ .name = "tag", .value = "" },
        },
    });

    const expected = "\x1b[1;32m(4cd65cc)\x1b[0m ";
    try std.testing.expectEqualStrings(expected, buf[0..pos]);
}

test "render git_commit with tag" {
    const BufferWriter = @import("../utils/buffer_writer.zig").BufferWriter;

    var cfg = Config{};
    cfg.git_commit.format = "[\\($hash$tag\\)]($style) ";
    cfg.git_commit.style = "bold green";

    var buf: [256]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);

    try formatter.formatTemplateWriter(writer, cfg.git_commit.format, .{
        .style = cfg.git_commit.style,
        .vars = &[_]formatter.Variable{
            .{ .name = "hash", .value = "4cd65cc" },
            .{ .name = "tag", .value = "  v1.0.0" },
        },
    });

    const expected = "\x1b[1;32m(4cd65cc  v1.0.0)\x1b[0m ";
    try std.testing.expectEqualStrings(expected, buf[0..pos]);
}

test "render git_commit disabled" {
    const BufferWriter = @import("../utils/buffer_writer.zig").BufferWriter;

    var cfg = Config{};
    cfg.git_commit.disabled = true;

    var buf: [256]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);

    try render(writer, cfg, .{ .cwd = "/some/path", .home = "." });

    try std.testing.expectEqual(@as(usize, 0), pos);
}
