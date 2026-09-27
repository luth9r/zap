const std = @import("std");
const testing = std.testing;
const Config = @import("../config/config.zig").Config;
const formatter = @import("formatter.zig");
const BufferWriter = @import("../utils/buffer_writer.zig").BufferWriter;
const directory_mod = @import("../modules/directory.zig");
const character_mod = @import("../modules/character.zig");

/// Execution context required to render the prompt.
pub const PromptContext = struct {
    cwd: []const u8,
    home: []const u8,
    status_code: u8 = 0,
};

/// Orchestrates rendering the complete prompt across all active modules according to the root format string.
pub fn render(writer: anytype, config: Config, ctx: PromptContext) !void {
    if (config.add_newline) {
        try writer.writeByte('\n');
    }

    var dir_buf: [std.fs.max_path_bytes + 256]u8 = undefined;
    var dir_pos: usize = 0;
    const dir_writer = BufferWriter.init(&dir_buf, &dir_pos);
    try directory_mod.render(dir_writer, config, ctx.cwd, ctx.home);

    var char_buf: [512]u8 = undefined;
    var char_pos: usize = 0;
    const char_writer = BufferWriter.init(&char_buf, &char_pos);
    try character_mod.render(char_writer, config, ctx.status_code);

    try formatter.formatTemplateWriter(writer, config.format, .{
        .vars = &[_]formatter.Variable{
            .{ .name = "directory", .value = dir_buf[0..dir_pos] },
            .{ .name = "character", .value = char_buf[0..char_pos] },
        },
    });
}

test "render prompt with default configuration" {
    var buf: [1024]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);
    var cfg = Config{};
    cfg.add_newline = false; // Disable leading newline for exact prefix test
    const ctx = PromptContext{
        .cwd = "/home/user/projects/zap",
        .home = "/home/user",
        .status_code = 0,
    };

    try render(writer, cfg, ctx);

    const expected = "\x1b[1;36m~/projects/zap\x1b[0m \x1b[1;32m❯\x1b[0m ";
    try testing.expectEqualStrings(expected, buf[0..pos]);
}

test "render prompt with error status and custom symbols" {
    var buf: [1024]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);
    var cfg = Config{};
    cfg.character.error_symbol = "[✗](bold red)";

    const ctx = PromptContext{
        .cwd = "/home/user",
        .home = "/home/user",
        .status_code = 1,
    };

    try render(writer, cfg, ctx);

    const expected = "\n\x1b[1;36m~\x1b[0m \x1b[1;31m✗\x1b[0m ";
    try testing.expectEqualStrings(expected, buf[0..pos]);
}

test "render prompt with disabled module" {
    var buf: [1024]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);
    var cfg = Config{};
    cfg.add_newline = false;
    cfg.directory.disabled = true;

    const ctx = PromptContext{
        .cwd = "/home/user/zap",
        .home = "/home/user",
        .status_code = 0,
    };

    try render(writer, cfg, ctx);

    const expected = "\x1b[1;32m❯\x1b[0m ";
    try testing.expectEqualStrings(expected, buf[0..pos]);
}

test "render prompt with custom root format" {
    var buf: [1024]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);
    var cfg = Config{};
    cfg.add_newline = false;
    cfg.format = "in $directory\n$character";
    cfg.directory.style = "cyan";
    cfg.character.success_symbol = "[➜](bold green)";

    const ctx = PromptContext{
        .cwd = "/home/user/zap",
        .home = "/home/user",
        .status_code = 0,
    };

    try render(writer, cfg, ctx);

    const expected = "in \x1b[36m~/zap\x1b[0m \n\x1b[1;32m➜\x1b[0m ";
    try testing.expectEqualStrings(expected, buf[0..pos]);
}

test "render multiline prompt with colored frame symbols" {
    var buf: [1024]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);
    var cfg = Config{};
    cfg.add_newline = false;
    cfg.format = "[┌─](bold yellow) $directory\n[└─](bold yellow)$character";
    cfg.directory.style = "bold cyan";
    cfg.character.success_symbol = "[❯](bold green)";

    const ctx = PromptContext{
        .cwd = "/home/user/projects/zap",
        .home = "/home/user",
        .status_code = 0,
    };

    try render(writer, cfg, ctx);

    const expected = "\x1b[1;33m┌─\x1b[0m \x1b[1;36m~/projects/zap\x1b[0m \n\x1b[1;33m└─\x1b[0m\x1b[1;32m❯\x1b[0m ";
    try testing.expectEqualStrings(expected, buf[0..pos]);
}
