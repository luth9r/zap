const std = @import("std");
const Config = @import("../config/config.zig").Config;
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

test "render git_state with merge operation" {
    const BufferWriter = @import("../utils/buffer_writer.zig").BufferWriter;

    var cfg = GitStateConfig{};
    cfg.format = "\\([$state]($style)\\) ";
    cfg.style = "bold yellow";

    var buf: [256]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);

    try formatter.formatTemplateWriter(writer, cfg.format, .{
        .style = cfg.style,
        .vars = &[_]formatter.Variable{
            .{ .name = "state", .value = cfg.merge },
            .{ .name = "progress_current", .value = "" },
            .{ .name = "progress_total", .value = "" },
        },
    });

    const expected = "(\x1b[1;33mMERGING\x1b[0m) ";
    try std.testing.expectEqualStrings(expected, buf[0..pos]);
}

test "render git_state with rebase progress" {
    const BufferWriter = @import("../utils/buffer_writer.zig").BufferWriter;

    var cfg = GitStateConfig{};
    cfg.format = "\\([$state( $progress_current/$progress_total)]($style)\\) ";
    cfg.style = "bold yellow";

    var buf: [256]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);

    try formatter.formatTemplateWriter(writer, cfg.format, .{
        .style = cfg.style,
        .vars = &[_]formatter.Variable{
            .{ .name = "state", .value = cfg.rebase },
            .{ .name = "progress_current", .value = "2" },
            .{ .name = "progress_total", .value = "5" },
        },
    });

    const expected = "(\x1b[1;33mREBASING 2/5\x1b[0m) ";
    try std.testing.expectEqualStrings(expected, buf[0..pos]);
}

test "render git_state disabled" {
    const BufferWriter = @import("../utils/buffer_writer.zig").BufferWriter;

    var cfg = GitStateConfig{};
    cfg.disabled = true;

    var buf: [256]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);

    try render(writer, cfg, .{ .cwd = "/some/path", .home = "." });

    try std.testing.expectEqual(@as(usize, 0), pos);
}

test "render git_state across all shells" {
    const BufferWriter = @import("../utils/buffer_writer.zig").BufferWriter;
    const Shell = @import("../init/root.zig").Shell;
    const assertValidShellAnsi = @import("../tests/fixture.zig").Fixture.assertValidShellAnsi;

    var cfg = GitStateConfig{};
    cfg.format = "\\([$state]($style)\\) ";
    cfg.style = "bold yellow";

    var buf: [256]u8 = undefined;
    const shells = [_]Shell{ .bash, .zsh, .fish, .powershell };

    for (shells) |sh| {
        var pos: usize = 0;
        const writer = BufferWriter.init(&buf, &pos);
        try formatter.formatTemplateWriter(writer, cfg.format, .{
            .style = cfg.style,
            .shell = sh,
            .vars = &[_]formatter.Variable{
                .{ .name = "state", .value = "REBASING" },
                .{ .name = "progress_current", .value = "" },
                .{ .name = "progress_total", .value = "" },
            },
        });
        const out = buf[0..pos];
        try assertValidShellAnsi(out, sh);
    }

    // Exact string verification for Bash
    var pos_bash: usize = 0;
    try formatter.formatTemplateWriter(BufferWriter.init(&buf, &pos_bash), cfg.format, .{
        .style = cfg.style,
        .shell = .bash,
        .vars = &[_]formatter.Variable{
            .{ .name = "state", .value = "REBASING" },
            .{ .name = "progress_current", .value = "" },
            .{ .name = "progress_total", .value = "" },
        },
    });
    try std.testing.expectEqualStrings("(\x01\x1b[1;33m\x02REBASING\x01\x1b[0m\x02) ", buf[0..pos_bash]);

    // Exact string verification for Zsh
    var pos_zsh: usize = 0;
    try formatter.formatTemplateWriter(BufferWriter.init(&buf, &pos_zsh), cfg.format, .{
        .style = cfg.style,
        .shell = .zsh,
        .vars = &[_]formatter.Variable{
            .{ .name = "state", .value = "REBASING" },
            .{ .name = "progress_current", .value = "" },
            .{ .name = "progress_total", .value = "" },
        },
    });
    try std.testing.expectEqualStrings("(%{\x1b[1;33m%}REBASING%{\x1b[0m%}) ", buf[0..pos_zsh]);
}

