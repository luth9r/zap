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
    config: Config,
    ctx: PromptContext,
) !void {
    if (config.directory.disabled) return;

    var repo_root_buf: [std.fs.max_path_bytes]u8 = undefined;
    var repo_root: ?[]const u8 = null;

    if (config.directory.truncate_to_repo) {
        if (ctx.io) |io_val| {
            if (@import("../utils/git_utils.zig").findGitDir(io_val, ctx.cwd, &repo_root_buf)) |git_dir| {
                if (std.mem.endsWith(u8, git_dir, "/.git")) {
                    repo_root = git_dir[0 .. git_dir.len - "/.git".len];
                }
            }
        }
    }

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_str = path_utils.formatPathTruncatedBuf(
        &path_buf,
        ctx.cwd,
        ctx.home,
        config.directory.home_symbol,
        config.directory.truncation_length,
        config.directory.truncation_symbol,
        repo_root,
    ) orelse ctx.cwd;

    try formatter.formatTemplateWriter(writer, config.directory.format, .{
        .style = config.directory.style,
        .vars = &[_]formatter.Variable{
            .{ .name = "path", .value = path_str },
            .{ .name = "read_only", .value = "" },
            .{ .name = "read_only_style", .value = config.directory.read_only_style },
        },
    });
}

test "render directory default with truncation" {
    const BufferWriter = @import("../utils/buffer_writer.zig").BufferWriter;

    var buf: [512]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);

    const cfg = Config{};
    try render(writer, cfg, .{ .cwd = "/home/user/projects/zap", .home = "/home/user" });

    const expected = "\x1b[1;36m~/projects/zap\x1b[0m ";
    try std.testing.expectEqualStrings(expected, buf[0..pos]);
}

test "render directory deep truncation" {
    const BufferWriter = @import("../utils/buffer_writer.zig").BufferWriter;

    var buf: [512]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);

    var cfg = Config{};
    cfg.directory.truncation_length = 3;
    cfg.directory.truncation_symbol = "…/";
    try render(writer, cfg, .{ .cwd = "/home/user/projects/code/zap/src/modules", .home = "/home/user" });

    const expected = "\x1b[1;36m~/…/zap/src/modules\x1b[0m ";
    try std.testing.expectEqualStrings(expected, buf[0..pos]);
}

test "render directory disabled" {
    const BufferWriter = @import("../utils/buffer_writer.zig").BufferWriter;

    var buf: [512]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);

    var cfg = Config{};
    cfg.directory.disabled = true;
    try render(writer, cfg, .{ .cwd = "/home/user/zap", .home = "/home/user" });

    try std.testing.expectEqual(@as(usize, 0), pos);
}

test "render directory custom style and home_symbol" {
    const BufferWriter = @import("../utils/buffer_writer.zig").BufferWriter;

    var buf: [512]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);

    var cfg = Config{};
    cfg.directory.style = "bold yellow";
    cfg.directory.home_symbol = "🏠";
    try render(writer, cfg, .{ .cwd = "/home/user/zap", .home = "/home/user" });

    const expected = "\x1b[1;33m🏠/zap\x1b[0m ";
    try std.testing.expectEqualStrings(expected, buf[0..pos]);
}
