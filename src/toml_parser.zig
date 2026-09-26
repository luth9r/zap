const std = @import("std");
const builtin = @import("builtin");
const Config = @import("config.zig").Config;
const color_utils = @import("color_utils.zig");

pub fn loadConfigFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    config: *Config,
) void {
    const EnvAdapter = struct {
        var map_ptr: *const std.process.Environ.Map = undefined;
        fn get(key: []const u8) ?[]const u8 {
            return map_ptr.get(key);
        }
    };
    EnvAdapter.map_ptr = environ_map;

    const config_path = (resolveConfigPath(allocator, EnvAdapter.get) catch return) orelse return;
    defer allocator.free(config_path);
    const file = std.Io.Dir.openFileAbsolute(io, config_path, .{}) catch return;
    defer file.close(io);

    var stream_buf: [4096]u8 = undefined;
    var file_reader = file.reader(io, &stream_buf);

    var content_buf: [64 * 1024]u8 = undefined;
    const bytes_read = file_reader.interface.readSliceShort(&content_buf) catch return;
    if (bytes_read == 0) return;

    parseToml(config, content_buf[0..bytes_read]);
}

const Section = enum {
    directory,
    path,
    character,
    prompt,
};

const DirKey = enum {
    home_symbol,
    home_color,
};

const CharKey = enum {
    success_symbol,
    error_symbol,
    success_color,
    error_color,
};

pub fn parseToml(config: *Config, content: []const u8) void {
    var line_it = std.mem.splitScalar(u8, content, '\n');
    var current_section: ?[]const u8 = null;

    while (line_it.next()) |raw_line| {
        // Trim whitespace from the line to handle leading/trailing spaces and tabs
        const line = std.mem.trim(u8, raw_line, " \t\r");

        // Skip empty lines and comments
        if (line.len == 0 or line[0] == '#') {
            continue;
        }

        // Section header [section]
        if (line[0] == '[' and line[line.len - 1] == ']') {
            current_section = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
            continue;
        }

        // Key-value
        if (std.mem.indexOfScalar(u8, line, '=')) |equal_idx| {
            var key = std.mem.trim(u8, line[0..equal_idx], " \t");
            var val = std.mem.trim(u8, line[equal_idx + 1 ..], " \t");

            if (key.len >= 2 and key[0] == '"' and key[key.len - 1] == '"') {
                key = key[1 .. key.len - 1];
            }

            if (std.mem.eql(u8, key, "$schema"))
                continue;

            if (current_section == null and std.mem.eql(u8, key, "add_newline")) {
                if (std.mem.eql(u8, val, "true")) {
                    config.add_newline = true;
                } else if (std.mem.eql(u8, val, "false")) {
                    config.add_newline = false;
                }
                continue;
            }

            // If the value is quoted, remove the quotes. This allows for values that contain spaces or special characters.
            if (val.len >= 2 and val[0] == '"' and val[val.len - 1] == '"') {
                val = val[1 .. val.len - 1];
            }

            applyValue(config, current_section, key, val);
        }
    }
}

fn applyValue(config: *Config, section: ?[]const u8, key: []const u8, val: []const u8) void {
    const sec_str = section orelse return;
    const sec = std.meta.stringToEnum(Section, sec_str) orelse return;

    switch (sec) {
        .directory, .path => {
            const dir_key = std.meta.stringToEnum(DirKey, key) orelse return;
            switch (dir_key) {
                .home_symbol => config.path.home_symbol = val,
                .home_color => config.path.home_color = color_utils.parseColor(val, config.path.home_color),
            }
        },
        .character, .prompt => {
            const char_key = std.meta.stringToEnum(CharKey, key) orelse return;
            switch (char_key) {
                .success_symbol => config.prompt.success_symbol = val,
                .error_symbol => config.prompt.error_symbol = val,
                .success_color => config.prompt.success_color = color_utils.parseColor(val, config.prompt.success_color),
                .error_color => config.prompt.error_color = color_utils.parseColor(val, config.prompt.error_color),
            }
        },
    }
}

fn resolveConfigPath(
    allocator: std.mem.Allocator,
    lookup_env: *const fn ([]const u8) ?[]const u8,
) !?[]const u8 {
    // User-defined configuration path via environment variable
    if (lookup_env("ZAP_CONFIG")) |custom| {
        return try allocator.dupe(u8, custom);
    }

    // XDG Base Directory Specification support ($XDG_CONFIG_HOME/zap/config.toml)
    if (lookup_env("XDG_CONFIG_HOME")) |xdg| {
        return try std.fs.path.join(allocator, &[_][]const u8{ xdg, "zap", "config.toml" });
    }

    // Windows-specific configuration path support (%APPDATA%\zap\config.toml)
    if (builtin.os.tag == .windows) {
        if (lookup_env("APPDATA")) |appdata| {
            return try std.fs.path.join(allocator, &[_][]const u8{ appdata, "zap", "config.toml" });
        }
    }

    // Universal fallback (~/.config/zap/config.toml)
    const home_env = if (builtin.os.tag == .windows) "USERPROFILE" else "HOME";
    if (lookup_env(home_env)) |home| {
        return try std.fs.path.join(allocator, &[_][]const u8{ home, ".config", "zap", "config.toml" });
    }

    return null;
}

test "parse empty string preserves default config" {
    var cfg = Config{};
    parseToml(&cfg, "");

    try std.testing.expectEqualStrings("~", cfg.path.home_symbol);
    try std.testing.expectEqualStrings(">", cfg.prompt.success_symbol);
}

test "parse comments and sections" {
    const toml_text =
        \\# Configuration
        \\
        \\[directory]
        \\home_symbol = "<>"
        \\
        \\[character]
        \\success_symbol = "➜"
        \\error_symbol = "X"
    ;

    var cfg = Config{};
    parseToml(&cfg, toml_text);

    try std.testing.expectEqualStrings("<>", cfg.path.home_symbol);
    try std.testing.expectEqualStrings("➜", cfg.prompt.success_symbol);
    try std.testing.expectEqualStrings("X", cfg.prompt.error_symbol);
}

test "resolveConfigPath respects ZAP_CONFIG priority" {
    const mockEnv = struct {
        fn get(key: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, key, "ZAP_CONFIG")) return "/custom/zap.toml";
            if (std.mem.eql(u8, key, "XDG_CONFIG_HOME")) return "/xdg";
            return null;
        }
    }.get;

    const path = (try resolveConfigPath(std.testing.allocator, mockEnv)).?;
    defer std.testing.allocator.free(path);

    try std.testing.expectEqualStrings("/custom/zap.toml", path);
}

test "resolveConfigPath resolves XDG_CONFIG_HOME" {
    const mockEnv = struct {
        fn get(key: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, key, "XDG_CONFIG_HOME")) return "/home/test/.custom_config";
            return null;
        }
    }.get;

    const path = (try resolveConfigPath(std.testing.allocator, mockEnv)).?;
    defer std.testing.allocator.free(path);

    const expected = try std.fs.path.join(std.testing.allocator, &[_][]const u8{
        "/home/test/.custom_config", "zap", "config.toml",
    });
    defer std.testing.allocator.free(expected);

    try std.testing.expectEqualStrings(expected, path);
}

test "resolveConfigPath falls back to HOME/.config/zap/config.toml" {
    const mockEnv = struct {
        fn get(key: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, key, "HOME")) return "/home/user";
            return null;
        }
    }.get;

    const path = (try resolveConfigPath(std.testing.allocator, mockEnv)).?;
    defer std.testing.allocator.free(path);

    const expected = try std.fs.path.join(std.testing.allocator, &[_][]const u8{
        "/home/user", ".config", "zap", "config.toml",
    });
    defer std.testing.allocator.free(expected);

    try std.testing.expectEqualStrings(expected, path);
}

test "integration: parseToml correctly updates full configuration" {
    const sample_config =
        \\# Example configuration for zap
        \\[directory]
        \\home_symbol = "★"
        \\home_color = "magenta"
        \\
        \\[character]
        \\success_symbol = ">>"
        \\error_symbol = "!!"
        \\success_color = "bold green"
        \\error_color = "bold red"
    ;

    var cfg = Config{};
    parseToml(&cfg, sample_config);

    try std.testing.expectEqualStrings("★", cfg.path.home_symbol);
    try std.testing.expectEqualStrings("\x1b[35m", cfg.path.home_color);
    try std.testing.expectEqualStrings(">>", cfg.prompt.success_symbol);
    try std.testing.expectEqualStrings("!!", cfg.prompt.error_symbol);
    try std.testing.expectEqualStrings("\x1b[1;32m", cfg.prompt.success_color);
    try std.testing.expectEqualStrings("\x1b[1;31m", cfg.prompt.error_color);
}

test "parseToml ignores $schema root key" {
    const toml_with_schema =
        \\"$schema" = "https://raw.githubusercontent.com/username/zap/main/zap.schema.json"
        \\
        \\[character]
        \\success_symbol = "»"
    ;

    var cfg = Config{};
    parseToml(&cfg, toml_with_schema);

    try std.testing.expectEqualStrings("»", cfg.prompt.success_symbol);
}
