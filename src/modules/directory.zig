const std = @import("std");
const Config = @import("../config/config.zig").Config;
const formatter = @import("../engine/formatter.zig");
const path_utils = @import("../utils/path_utils.zig");

pub const PromptContext = @import("../engine/context.zig").PromptContext;

pub const buffer_size: usize = std.fs.max_path_bytes + 256;

pub const DirectoryConfig = struct {
    // Format string used to render the directory module.
    format: []const u8 = "[$path]($style)[$read_only]($read_only_style) ",
    // Style string for the directory path.
    style: []const u8 = "bold cyan",
    // Replacement symbol for the user home directory.
    home_symbol: []const u8 = "~",
    // Symbol shown when the directory is read-only (Nerd Font lock icon).
    read_only: []const u8 = "󰌾",
    // Style string for the read-only symbol.
    read_only_style: []const u8 = "bold red",
    // Number of path components to show (0 = no truncation, default = 3).
    truncation_length: usize = 3,
    // Symbol replacing truncated path elements.
    truncation_symbol: []const u8 = "…/",
    // Whether to truncate path relative to git repository root.
    truncate_to_repo: bool = true,
    // Whether the directory module is disabled.
    disabled: bool = false,
};

/// Renders the directory module according to the directory configuration.
pub fn render(
    writer: anytype,
    config: DirectoryConfig,
    ctx: PromptContext,
) !void {
    if (config.disabled) return;

    var repo_root_buf: [std.fs.max_path_bytes]u8 = undefined;
    var repo_root: ?[]const u8 = null;

    if (config.truncate_to_repo) {
        const git_dir_opt = ctx.git_dir orelse if (ctx.io) |io_val|
            @import("../utils/git_utils.zig").findGitDir(io_val, ctx.cwd, &repo_root_buf)
        else
            null;
        if (git_dir_opt) |git_dir| {
            if (std.mem.endsWith(u8, git_dir, "/.git")) {
                repo_root = git_dir[0 .. git_dir.len - "/.git".len];
            } else {
                repo_root = std.fs.path.dirname(git_dir) orelse git_dir;
            }
        }
    }

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_str = path_utils.formatPathTruncatedBuf(
        &path_buf,
        ctx.cwd,
        ctx.home,
        config.home_symbol,
        config.truncation_length,
        config.truncation_symbol,
        repo_root,
    ) orelse ctx.cwd;

    try formatter.formatTemplateWriter(writer, config.format, .{
        .style = config.style,
        .shell = ctx.shell,
        .vars = &[_]formatter.Variable{
            .{ .name = "path", .value = path_str },
            .{ .name = "read_only", .value = "" },
            .{ .name = "read_only_style", .value = config.read_only_style },
        },
    });
}

test "render directory default with truncation" {
    const BufferWriter = @import("../utils/buffer_writer.zig").BufferWriter;

    var buf: [512]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);

    const cfg = DirectoryConfig{};
    try render(writer, cfg, .{ .cwd = "/home/user/projects/zap", .home = "/home/user" });

    const expected = "\x1b[1;36m~/projects/zap\x1b[0m ";
    try std.testing.expectEqualStrings(expected, buf[0..pos]);
}

test "render directory deep truncation" {
    const BufferWriter = @import("../utils/buffer_writer.zig").BufferWriter;

    var buf: [512]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);

    var cfg = DirectoryConfig{};
    cfg.truncation_length = 3;
    cfg.truncation_symbol = "…/";
    try render(writer, cfg, .{ .cwd = "/home/user/projects/code/zap/src/modules", .home = "/home/user" });

    const expected = "\x1b[1;36m~/…/zap/src/modules\x1b[0m ";
    try std.testing.expectEqualStrings(expected, buf[0..pos]);
}

test "render directory disabled" {
    const BufferWriter = @import("../utils/buffer_writer.zig").BufferWriter;

    var buf: [512]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);

    var cfg = DirectoryConfig{};
    cfg.disabled = true;
    try render(writer, cfg, .{ .cwd = "/home/user/zap", .home = "/home/user" });

    try std.testing.expectEqual(@as(usize, 0), pos);
}

test "render directory custom style and home_symbol" {
    const BufferWriter = @import("../utils/buffer_writer.zig").BufferWriter;

    var buf: [512]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);

    var cfg = DirectoryConfig{};
    cfg.style = "bold yellow";
    cfg.home_symbol = "🏠";
    try render(writer, cfg, .{ .cwd = "/home/user/zap", .home = "/home/user" });

    const expected = "\x1b[1;33m🏠/zap\x1b[0m ";
    try std.testing.expectEqualStrings(expected, buf[0..pos]);
}

test "render directory across all shells" {
    const BufferWriter = @import("../utils/buffer_writer.zig").BufferWriter;
    const Shell = @import("../init/root.zig").Shell;
    const assertValidShellAnsi = @import("../tests/fixture.zig").Fixture.assertValidShellAnsi;

    var buf: [512]u8 = undefined;
    const cfg = DirectoryConfig{};
    const shells = [_]Shell{ .bash, .zsh, .fish, .powershell };

    for (shells) |sh| {
        var pos: usize = 0;
        const writer = BufferWriter.init(&buf, &pos);
        try render(writer, cfg, .{
            .cwd = "/home/user/projects/zap",
            .home = "/home/user",
            .shell = sh,
        });
        const out = buf[0..pos];
        try assertValidShellAnsi(out, sh);
        try std.testing.expect(std.mem.indexOf(u8, out, "~/projects/zap") != null);
    }

    // Exact string verification for Bash
    var pos_bash: usize = 0;
    try render(BufferWriter.init(&buf, &pos_bash), cfg, .{
        .cwd = "/home/user/projects/zap",
        .home = "/home/user",
        .shell = .bash,
    });
    try std.testing.expectEqualStrings("\x01\x1b[1;36m\x02~/projects/zap\x01\x1b[0m\x02 ", buf[0..pos_bash]);

    // Exact string verification for Zsh
    var pos_zsh: usize = 0;
    try render(BufferWriter.init(&buf, &pos_zsh), cfg, .{
        .cwd = "/home/user/projects/zap",
        .home = "/home/user",
        .shell = .zsh,
    });
    try std.testing.expectEqualStrings("%{\x1b[1;36m%}~/projects/zap%{\x1b[0m%} ", buf[0..pos_zsh]);
}

