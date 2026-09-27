const std = @import("std");
const Config = @import("../config/config.zig").Config;
const formatter = @import("../engine/formatter.zig");
const git_utils = @import("../utils/git_utils.zig");

pub const PromptContext = @import("../engine/context.zig").PromptContext;

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
    config: Config,
    ctx: PromptContext,
) !void {
    if (config.git_state.disabled) return;
    const io = ctx.io orelse return;

    var git_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const git_dir = git_utils.findGitDir(io, ctx.cwd, &git_dir_buf) orelse return;

    var cur_buf: [32]u8 = undefined;
    var total_buf: [32]u8 = undefined;
    const state_res = git_utils.getGitState(io, git_dir, &cur_buf, &total_buf);

    const state_label = switch (state_res.state_type) {
        .none => return,
        .rebase => config.git_state.rebase,
        .merge => config.git_state.merge,
        .revert => config.git_state.revert,
        .cherry_pick => config.git_state.cherry_pick,
        .bisect => config.git_state.bisect,
        .am => config.git_state.am,
        .am_or_rebase => config.git_state.am_or_rebase,
    };

    try formatter.formatTemplateWriter(writer, config.git_state.format, .{
        .style = config.git_state.style,
        .vars = &[_]formatter.Variable{
            .{ .name = "state", .value = state_label },
            .{ .name = "progress_current", .value = state_res.progress_current },
            .{ .name = "progress_total", .value = state_res.progress_total },
        },
    });
}

test "render git_state with merge operation" {
    const BufferWriter = @import("../utils/buffer_writer.zig").BufferWriter;

    var cfg = Config{};
    cfg.git_state.format = "\\([$state]($style)\\) ";
    cfg.git_state.style = "bold yellow";

    var buf: [256]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);

    try formatter.formatTemplateWriter(writer, cfg.git_state.format, .{
        .style = cfg.git_state.style,
        .vars = &[_]formatter.Variable{
            .{ .name = "state", .value = cfg.git_state.merge },
            .{ .name = "progress_current", .value = "" },
            .{ .name = "progress_total", .value = "" },
        },
    });

    const expected = "(\x1b[1;33mMERGING\x1b[0m) ";
    try std.testing.expectEqualStrings(expected, buf[0..pos]);
}

test "render git_state with rebase progress" {
    const BufferWriter = @import("../utils/buffer_writer.zig").BufferWriter;

    var cfg = Config{};
    cfg.git_state.format = "\\([$state( $progress_current/$progress_total)]($style)\\) ";
    cfg.git_state.style = "bold yellow";

    var buf: [256]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);

    try formatter.formatTemplateWriter(writer, cfg.git_state.format, .{
        .style = cfg.git_state.style,
        .vars = &[_]formatter.Variable{
            .{ .name = "state", .value = cfg.git_state.rebase },
            .{ .name = "progress_current", .value = "2" },
            .{ .name = "progress_total", .value = "5" },
        },
    });

    const expected = "(\x1b[1;33mREBASING 2/5\x1b[0m) ";
    try std.testing.expectEqualStrings(expected, buf[0..pos]);
}

test "render git_state disabled" {
    const BufferWriter = @import("../utils/buffer_writer.zig").BufferWriter;

    var cfg = Config{};
    cfg.git_state.disabled = true;

    var buf: [256]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);

    try render(writer, cfg, .{ .cwd = "/some/path", .home = "." });

    try std.testing.expectEqual(@as(usize, 0), pos);
}
