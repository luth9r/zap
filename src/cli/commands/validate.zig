const std = @import("std");
const toml_parser = @import("../../config/toml_parser.zig");
const validator = @import("../../config/validator.zig");
const BufferWriter = @import("../../utils/buffer_writer.zig").BufferWriter;

pub const Args = struct {
    config_path: ?[]const u8 = null,
};

pub fn execute(init: std.process.Init, v_args: Args) !void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const EnvAdapter = struct {
        var map_ptr: *const std.process.Environ.Map = undefined;
        fn get(key: []const u8) ?[]const u8 {
            return map_ptr.get(key);
        }
    };
    EnvAdapter.map_ptr = init.environ_map;

    const config_path = v_args.config_path orelse
        toml_parser.resolveExistingConfigPath(init.io, &path_buf, EnvAdapter.get) orelse
        "~/.config/zap/zap.toml";

    var diag_buf: [32768]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&diag_buf, &pos);

    const res = try validator.validateFile(init.io, config_path, writer);
    try std.Io.File.stdout().writeStreamingAll(init.io, diag_buf[0..pos]);

    if (!res.isValid()) {
        std.process.exit(1);
    }
}

const testing = std.testing;
const Harness = @import("../../tests/harness.zig").Harness;

test "integration: zap validate with valid configuration" {
    var h = try Harness.create(testing.allocator);
    defer h.destroy();

    try h.writeFile(".config/zap/zap.toml",
        \\add_newline = true
        \\format = "$directory$git_branch$character"
        \\
        \\[directory]
        \\style = "bold cyan"
        \\truncation_length = 3
        \\
        \\[character]
        \\success_symbol = "[❯](bold green)"
    );

    const res = try h.execZapAllowFail(&.{"validate"});
    try testing.expectEqual(@as(u8, 0), res.exit_code);
    try Harness.expectContains(res.stdout, "is valid");
}

test "integration: zap validate with typos in section name" {
    var h = try Harness.create(testing.allocator);
    defer h.destroy();

    try h.writeFile("broken.toml",
        \\[directry]
        \\style = "bold cyan"
    );

    const res = try h.execZapAllowFail(&.{ "validate", "broken.toml" });
    try testing.expectEqual(@as(u8, 1), res.exit_code);
    try Harness.expectContains(res.stdout, "unknown section '[directry]'");
}

test "integration: zap validate with invalid style" {
    var h = try Harness.create(testing.allocator);
    defer h.destroy();

    try h.writeFile("broken_style.toml",
        \\[directory]
        \\style = "bold invalidcolor"
    );

    const res = try h.execZapAllowFail(&.{ "validate", "broken_style.toml" });
    try testing.expectEqual(@as(u8, 1), res.exit_code);
    try Harness.expectContains(res.stdout, "invalid style");
    try Harness.expectContains(res.stdout, "invalidcolor");
}

test "integration: zap validate with unknown variable in format" {
    var h = try Harness.create(testing.allocator);
    defer h.destroy();

    try h.writeFile("broken_format.toml",
        \\format = "$directory$unknown_module"
    );

    const res = try h.execZapAllowFail(&.{ "validate", "broken_format.toml" });
    try testing.expectEqual(@as(u8, 1), res.exit_code);
    try Harness.expectContains(res.stdout, "unknown variable '$unknown_module'");
}

test "integration: zap validate via --config flag" {
    var h = try Harness.create(testing.allocator);
    defer h.destroy();

    try h.writeFile("custom/my_config.toml",
        \\add_newline = false
        \\format = "$directory$character"
    );

    const res = try h.execZapAllowFail(&.{ "validate", "--config", "custom/my_config.toml" });
    try testing.expectEqual(@as(u8, 0), res.exit_code);
    try Harness.expectContains(res.stdout, "is valid");
}

test "integration: zap validate with root level module warning" {
    var h = try Harness.create(testing.allocator);
    defer h.destroy();

    try h.writeFile("warning_config.toml",
        \\add_newline = false
        \\format = "$directory$character"
        \\directory = "bold cyan"
    );

    const res = try h.execZapAllowFail(&.{ "validate", "warning_config.toml" });
    try testing.expectEqual(@as(u8, 0), res.exit_code);
    try Harness.expectContains(res.stdout, "Warning");
    try Harness.expectContains(res.stdout, "'directory' specified at root level; did you mean '[directory]'?");
    try Harness.expectContains(res.stdout, "is valid with 1 warning(s)");
}

test "integration: zap validate with bare unquoted word syntax error" {
    var h = try Harness.create(testing.allocator);
    defer h.destroy();

    try h.writeFile("bare_word.toml",
        \\add_newline = true
        \\directory
        \\format = "[$path]($style) "
    );

    const res = try h.execZapAllowFail(&.{ "validate", "bare_word.toml" });
    try testing.expectEqual(@as(u8, 1), res.exit_code);
    try Harness.expectContains(res.stdout, "syntax error, expected 'key = value', got 'directory'");
}

test "integration: zap validate with unclosed and empty section headers" {
    var h = try Harness.create(testing.allocator);
    defer h.destroy();

    try h.writeFile("unclosed_sec.toml",
        \\[directory
        \\style = "bold cyan"
    );

    const res1 = try h.execZapAllowFail(&.{ "validate", "unclosed_sec.toml" });
    try testing.expectEqual(@as(u8, 1), res1.exit_code);
    try Harness.expectContains(res1.stdout, "unclosed section header '[directory'");

    try h.writeFile("empty_sec.toml",
        \\[]
        \\style = "bold cyan"
    );

    const res2 = try h.execZapAllowFail(&.{ "validate", "empty_sec.toml" });
    try testing.expectEqual(@as(u8, 1), res2.exit_code);
    try Harness.expectContains(res2.stdout, "empty section header '[]'");
}

test "integration: zap validate with unclosed quotes in property value" {
    var h = try Harness.create(testing.allocator);
    defer h.destroy();

    try h.writeFile("unclosed_quote.toml",
        \\[directory]
        \\style = "bold cyan
    );

    const res = try h.execZapAllowFail(&.{ "validate", "unclosed_quote.toml" });
    try testing.expectEqual(@as(u8, 1), res.exit_code);
    try Harness.expectContains(res.stdout, "unclosed quote in value for 'style'");
}

test "integration: zap validate with invalid boolean and integer values" {
    var h = try Harness.create(testing.allocator);
    defer h.destroy();

    try h.writeFile("type_mismatch.toml",
        \\add_newline = "yes"
        \\
        \\[directory]
        \\truncation_length = "four"
        \\disabled = "no"
    );

    const res = try h.execZapAllowFail(&.{ "validate", "type_mismatch.toml" });
    try testing.expectEqual(@as(u8, 1), res.exit_code);
    try Harness.expectContains(res.stdout, "invalid boolean for 'add_newline'");
    try Harness.expectContains(res.stdout, "invalid integer for 'truncation_length'");
    try Harness.expectContains(res.stdout, "invalid boolean for 'disabled'");
}

test "integration: zap validate with unclosed and unexpected brackets in format" {
    var h = try Harness.create(testing.allocator);
    defer h.destroy();

    try h.writeFile("bad_brackets.toml",
        \\format = "[$directory$character"
        \\
        \\[directory]
        \\format = "[$path](bold red"
    );

    const res1 = try h.execZapAllowFail(&.{ "validate", "bad_brackets.toml" });
    try testing.expectEqual(@as(u8, 1), res1.exit_code);
    try Harness.expectContains(res1.stdout, "unclosed bracket '[' in root format");
    try Harness.expectContains(res1.stdout, "unclosed style parentheses in [directory] format");

    try h.writeFile("unexpected_brackets.toml",
        \\format = "$directory]$character)"
    );

    const res2 = try h.execZapAllowFail(&.{ "validate", "unexpected_brackets.toml" });
    try testing.expectEqual(@as(u8, 1), res2.exit_code);
    try Harness.expectContains(res2.stdout, "unexpected closing bracket ']' in root format");
    try Harness.expectContains(res2.stdout, "unexpected closing parenthesis ')' in root format");
}

test "integration: zap validate with unknown module format variable" {
    var h = try Harness.create(testing.allocator);
    defer h.destroy();

    try h.writeFile("bad_mod_var.toml",
        \\[git_branch]
        \\format = "[$symbol $path]($style) "
    );

    const res = try h.execZapAllowFail(&.{ "validate", "bad_mod_var.toml" });
    try testing.expectEqual(@as(u8, 1), res.exit_code);
    try Harness.expectContains(res.stdout, "unknown variable '$path' in [git_branch] format");
}

test "integration: zap validate with non existent file" {
    var h = try Harness.create(testing.allocator);
    defer h.destroy();

    const res = try h.execZapAllowFail(&.{ "validate", "does_not_exist.toml" });
    try testing.expectEqual(@as(u8, 1), res.exit_code);
    try Harness.expectContains(res.stdout, "failed to open config file 'does_not_exist.toml'");
}

test "integration: zap validate with invalid style token" {
    var h = try Harness.create(testing.allocator);
    defer h.destroy();

    try h.writeFile("bad_style.toml",
        \\[directory]
        \\style = "blinking_rainbow_supercolor"
    );

    const res = try h.execZapAllowFail(&.{ "validate", "bad_style.toml" });
    try testing.expectEqual(@as(u8, 1), res.exit_code);
    try Harness.expectContains(res.stdout, "invalid style for 'style' in [directory]");
    try Harness.expectContains(res.stdout, "unknown token 'blinking_rainbow_supercolor'");
}
