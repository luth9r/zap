const std = @import("std");
const testing = std.testing;
const Config = @import("../config/config.zig").Config;
const formatter = @import("formatter.zig");
const BufferWriter = @import("../utils/buffer_writer.zig").BufferWriter;
pub const PromptContext = @import("context.zig").PromptContext;
pub const modules = @import("../modules/registry.zig");

fn isModuleRequested(format: []const u8, comptime name: []const u8) bool {
    return std.mem.indexOf(u8, format, "$" ++ name) != null;
}

/// Orchestrates rendering the complete prompt across all active modules using comptime reflection.
pub fn render(writer: anytype, config: Config, ctx: PromptContext) !void {
    if (config.add_newline) {
        try writer.writeByte('\n');
    }

    const decls = @typeInfo(modules).@"struct".decls;
    var vars: [decls.len]formatter.Variable = undefined;

    inline for (decls, 0..) |decl, i| {
        const mod = @field(modules, decl.name);
        const buf_size = if (@hasDecl(mod, "buffer_size")) mod.buffer_size else 512;
        var buf: [buf_size]u8 = undefined;
        var pos: usize = 0;

        if (isModuleRequested(config.format, decl.name)) {
            const mod_writer = BufferWriter.init(&buf, &pos);
            try mod.render(mod_writer, config, ctx);
        }

        vars[i] = .{
            .name = decl.name,
            .value = buf[0..pos],
        };
    }

    try formatter.formatTemplateWriter(writer, config.format, .{
        .vars = &vars,
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

test "render prompt with cmd_duration module" {
    var buf: [1024]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);
    var cfg = Config{};
    cfg.add_newline = false;
    cfg.format = "$directory$cmd_duration$character";

    // Case 1: duration exceeds default min_time (2000ms)
    const ctx1 = PromptContext{
        .cwd = "/home/user/zap",
        .home = "/home/user",
        .status_code = 0,
        .cmd_duration = 3500,
    };

    try render(writer, cfg, ctx1);
    const expected1 = "\x1b[1;36m~/zap\x1b[0m took \x1b[1;33m3s\x1b[0m \x1b[1;32m❯\x1b[0m ";
    try testing.expectEqualStrings(expected1, buf[0..pos]);

    // Case 2: duration below min_time (1000ms) -> cmd_duration is hidden
    pos = 0;
    const ctx2 = PromptContext{
        .cwd = "/home/user/zap",
        .home = "/home/user",
        .status_code = 0,
        .cmd_duration = 1000,
    };

    try render(writer, cfg, ctx2);
    const expected2 = "\x1b[1;36m~/zap\x1b[0m \x1b[1;32m❯\x1b[0m ";
    try testing.expectEqualStrings(expected2, buf[0..pos]);
}

test "render prompt with git_status module variables" {
    var buf: [1024]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);
    var cfg = Config{};
    cfg.add_newline = false;
    cfg.format = "$directory$git_branch$git_status$character";

    try formatter.formatTemplateWriter(writer, cfg.format, .{
        .vars = &[_]formatter.Variable{
            .{ .name = "directory", .value = "\x1b[1;36m~/zap\x1b[0m " },
            .{ .name = "git_branch", .value = "on \x1b[1;35mmain\x1b[0m " },
            .{ .name = "git_status", .value = "\x1b[1;31m[!+]\x1b[0m " },
            .{ .name = "character", .value = "\x1b[1;32m❯\x1b[0m " },
        },
    });

    const expected = "\x1b[1;36m~/zap\x1b[0m on \x1b[1;35mmain\x1b[0m \x1b[1;31m[!+]\x1b[0m \x1b[1;32m❯\x1b[0m ";
    try testing.expectEqualStrings(expected, buf[0..pos]);
}

test "render prompt with all git modules in root format" {
    var buf: [1024]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);
    var cfg = Config{};
    cfg.add_newline = false;
    cfg.format = "$directory$git_branch$git_commit$git_state$git_status$git_metrics$character";

    try formatter.formatTemplateWriter(writer, cfg.format, .{
        .vars = &[_]formatter.Variable{
            .{ .name = "directory", .value = "\x1b[1;36m~/zap\x1b[0m " },
            .{ .name = "git_branch", .value = "on \x1b[1;35mmain\x1b[0m " },
            .{ .name = "git_commit", .value = "\x1b[1;32m(4cd65cc)\x1b[0m " },
            .{ .name = "git_state", .value = "(\x1b[1;33mREBASING 1/3\x1b[0m) " },
            .{ .name = "git_status", .value = "\x1b[1;31m[!+]\x1b[0m " },
            .{ .name = "git_metrics", .value = "\x1b[1;32m+10\x1b[0m \x1b[1;31m-2\x1b[0m " },
            .{ .name = "character", .value = "\x1b[1;32m❯\x1b[0m " },
        },
    });

    const expected = "\x1b[1;36m~/zap\x1b[0m on \x1b[1;35mmain\x1b[0m \x1b[1;32m(4cd65cc)\x1b[0m (\x1b[1;33mREBASING 1/3\x1b[0m) \x1b[1;31m[!+]\x1b[0m \x1b[1;32m+10\x1b[0m \x1b[1;31m-2\x1b[0m \x1b[1;32m❯\x1b[0m ";
    try testing.expectEqualStrings(expected, buf[0..pos]);
}

