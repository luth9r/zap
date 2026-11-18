const std = @import("std");
const config_mod = @import("config.zig");
const platform = @import("../utils/platform.zig");
const fs = @import("../utils/fs.zig");

const DOT_CONFIG_DIR = ".config";
const CONFIG_DIR_NAME = "zap";
const DEFAULT_CONFIG_FILE = "zap.toml";
const CONFIG_CANDIDATES = [_][]const u8{ DEFAULT_CONFIG_FILE, "config.toml" };

pub fn loadConfigFromPath(
    io: std.Io,
    config_path: []const u8,
    config: *config_mod.Config,
    content_buf: []u8,
) usize {
    const content = fs.readFileRaw(io, config_path, content_buf) orelse return 0;
    parseToml(config, content);
    return content.len;
}

pub fn loadConfigFile(
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    config: *config_mod.Config,
    content_buf: []u8,
) void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const config_path = resolveExistingConfigPath(io, &path_buf, environ_map) orelse return;
    _ = loadConfigFromPath(io, config_path, config, content_buf);
}

/// Parses a section header `[section]` if the line is a section declaration (ignoring trailing comments).
pub fn parseSectionHeader(line: []const u8) ?[]const u8 {
    const clean = stripInlineComment(line);
    if (clean.len >= 2 and clean[0] == '[' and clean[clean.len - 1] == ']') {
        return std.mem.trim(u8, clean[1 .. clean.len - 1], " \t");
    }
    return null;
}

/// Splits a `key = val` line/pair, trimming whitespace and unquoting double-quoted keys.
pub fn splitKeyVal(item: []const u8) ?struct { key: []const u8, val: []const u8 } {
    const eq_idx = std.mem.indexOfScalar(u8, item, '=') orelse return null;
    var k = std.mem.trim(u8, item[0..eq_idx], " \t");
    const v = std.mem.trim(u8, item[eq_idx + 1 ..], " \t");
    if (k.len >= 2 and k[0] == '"' and k[k.len - 1] == '"') {
        k = k[1 .. k.len - 1];
    }
    return .{ .key = k, .val = v };
}

/// Strips surrounding matching double or single quotes from a slice.
pub fn unquoteRaw(val: []const u8) []const u8 {
    if (val.len >= 2 and ((val[0] == '"' and val[val.len - 1] == '"') or (val[0] == '\'' and val[val.len - 1] == '\''))) {
        return val[1 .. val.len - 1];
    }
    return val;
}

/// Strips an unquoted trailing inline comment (`# ...`) from a single-line TOML value.
pub fn stripInlineComment(val: []const u8) []const u8 {
    var in_quote: ?u8 = null;
    var i: usize = 0;
    while (i < val.len) : (i += 1) {
        const c = val[i];
        if (in_quote) |q| {
            if (c == '\\' and q == '"' and i + 1 < val.len) {
                i += 1;
                continue;
            }
            if (c == q) {
                in_quote = null;
            }
        } else {
            if (c == '"' or c == '\'') {
                in_quote = c;
            } else if (c == '#') {
                return std.mem.trimEnd(u8, val[0..i], " \t\r");
            }
        }
    }
    return val;
}

/// Unquotes simple double- or single-quoted string values.
pub fn unquoteValue(raw_val: []const u8) []const u8 {
    return unquoteRaw(stripInlineComment(raw_val));
}

/// Extracts a multiline string enclosed in triple quotes (""" or ''').
pub fn extractMultilineValue(val: []const u8, content: []const u8, line_it: *std.mem.SplitIterator(u8, .scalar)) []const u8 {
    const quote_type = val[0..3];
    var multiline_slice = val[3..];
    if (multiline_slice.len >= 3 and std.mem.endsWith(u8, multiline_slice, quote_type)) {
        return multiline_slice[0 .. multiline_slice.len - 3];
    }

    const val_start_in_content = @intFromPtr(multiline_slice.ptr) - @intFromPtr(content.ptr);
    var end_pos: ?usize = null;
    while (line_it.next()) |next_raw| {
        if (std.mem.indexOf(u8, next_raw, quote_type)) |closing_idx| {
            const line_offset = @intFromPtr(next_raw.ptr) - @intFromPtr(content.ptr);
            end_pos = line_offset + closing_idx;
            break;
        }
    }
    if (end_pos) |ep| {
        if (ep >= val_start_in_content) {
            var multiline_raw = content[val_start_in_content..ep];
            if (multiline_raw.len > 0 and multiline_raw[0] == '\n') {
                multiline_raw = multiline_raw[1..];
            } else if (multiline_raw.len > 1 and multiline_raw[0] == '\r' and multiline_raw[1] == '\n') {
                multiline_raw = multiline_raw[2..];
            }
            return multiline_raw;
        }
    }
    return val;
}

pub const TomlSyntaxError = enum {
    unclosed_section,
    empty_section,
    expected_key_val,
    unclosed_multiline,
    unclosed_inline_table,
    unclosed_quote,
};

pub const TomlInlineError = enum {
    expected_key_val,
    unclosed_quote,
};

pub fn hasOddTrailingBackslashes(slice: []const u8) bool {
    var count: usize = 0;
    var i: usize = slice.len;
    while (i > 0) {
        i -= 1;
        if (slice[i] == '\\') {
            count += 1;
        } else {
            break;
        }
    }
    return (count % 2) == 1;
}

/// Unquotes a single-line TOML value, returning `null` if it starts with a quote that is not properly closed.
pub fn unquoteChecked(val: []const u8) ?[]const u8 {
    if (val.len == 0) return val;
    const q = val[0];
    if (q == '"' or q == '\'') {
        if (val.len < 2 or val[val.len - 1] != q) return null;
        if (q == '"' and hasOddTrailingBackslashes(val[1 .. val.len - 1])) return null;
        return val[1 .. val.len - 1];
    }
    return val;
}

/// Shared zero-allocation TOML scanner used by both `parseToml` and `validator.validateContent`.
pub fn scanToml(content: []const u8, handler: anytype) !void {
    var line_it = std.mem.splitScalar(u8, content, '\n');
    var line_num: usize = 0;
    var current_section: ?[]const u8 = null;

    while (line_it.next()) |raw_line| {
        line_num += 1;
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        if (line[0] == '[') {
            const clean_sec = stripInlineComment(line);
            if (clean_sec.len < 2 or clean_sec[clean_sec.len - 1] != ']') {
                try handler.onSyntaxError(line_num, .unclosed_section, line);
                continue;
            }
            const sec = std.mem.trim(u8, clean_sec[1 .. clean_sec.len - 1], " \t");
            if (sec.len == 0) {
                try handler.onSyntaxError(line_num, .empty_section, line);
                continue;
            }
            current_section = sec;
            try handler.onSection(line_num, sec);
            continue;
        }

        const kv = splitKeyVal(line) orelse {
            try handler.onSyntaxError(line_num, .expected_key_val, line);
            continue;
        };
        const key = kv.key;
        var val = kv.val;

        if (std.mem.eql(u8, key, "$schema")) continue;

        if (val.len >= 3 and (std.mem.startsWith(u8, val, "\"\"\"") or std.mem.startsWith(u8, val, "'''"))) {
            const quote_type = val[0..3];
            const after_open = val[3..];
            const has_closing = (after_open.len >= 3 and std.mem.endsWith(u8, after_open, quote_type)) or
                (std.mem.indexOf(u8, content[(@intFromPtr(after_open.ptr) - @intFromPtr(content.ptr))..], quote_type) != null);
            if (!has_closing) {
                try handler.onSyntaxError(line_num, .unclosed_multiline, key);
                break;
            }
            val = extractMultilineValue(val, content, &line_it);
            try handler.onKeyValue(line_num, current_section, key, val);
            continue;
        }

        const clean_val = stripInlineComment(val);
        if (clean_val.len > 0 and clean_val[0] == '{') {
            if (clean_val.len < 2 or clean_val[clean_val.len - 1] != '}') {
                try handler.onSyntaxError(line_num, .unclosed_inline_table, key);
                continue;
            }
            const target_sec = if (isConfigSectionField(key)) key else (current_section orelse key);
            const inner = std.mem.trim(u8, clean_val[1 .. clean_val.len - 1], " \t\r");
            var it = InlineTableIterator.init(inner);
            while (it.next()) |pair| {
                const trimmed_item = std.mem.trim(u8, pair, " \t\r");
                if (trimmed_item.len == 0) continue;
                const item_kv = splitKeyVal(trimmed_item) orelse {
                    try handler.onInlineError(line_num, target_sec, .expected_key_val, trimmed_item);
                    continue;
                };
                const unquoted_v = unquoteChecked(item_kv.val) orelse {
                    try handler.onInlineError(line_num, target_sec, .unclosed_quote, item_kv.key);
                    continue;
                };
                try handler.onInlineKeyValue(line_num, target_sec, item_kv.key, unquoted_v);
            }
            continue;
        }

        const unquoted_val = unquoteChecked(clean_val) orelse {
            try handler.onSyntaxError(line_num, .unclosed_quote, key);
            continue;
        };
        try handler.onKeyValue(line_num, current_section, key, unquoted_val);
    }
}

/// Parses TOML content directly into Config without heap allocations using comptime reflection.
pub fn parseToml(config: *config_mod.Config, content: []const u8) void {
    const Handler = struct {
        cfg: *config_mod.Config,

        pub fn onSection(_: @This(), _: usize, _: []const u8) !void {}
        pub fn onSyntaxError(_: @This(), _: usize, _: TomlSyntaxError, _: []const u8) !void {}
        pub fn onInlineError(_: @This(), _: usize, _: []const u8, _: TomlInlineError, _: []const u8) !void {}

        pub fn onKeyValue(self: @This(), _: usize, section: ?[]const u8, key: []const u8, val: []const u8) !void {
            applyValue(self.cfg, section, key, val);
        }

        pub fn onInlineKeyValue(self: @This(), _: usize, target_sec: []const u8, key: []const u8, val: []const u8) !void {
            applyValue(self.cfg, target_sec, key, val);
        }
    };
    scanToml(content, Handler{ .cfg = config }) catch {};
}

/// Quote-aware iterator over comma-separated `key = value` pairs inside a TOML inline table.
pub const InlineTableIterator = struct {
    content: []const u8,
    pos: usize = 0,

    pub fn init(content_inside: []const u8) InlineTableIterator {
        return .{ .content = content_inside };
    }

    pub fn next(self: *InlineTableIterator) ?[]const u8 {
        if (self.pos >= self.content.len) return null;

        const pair_start = self.pos;
        var i = self.pos;
        var in_quotes: ?u8 = null;

        while (i < self.content.len) : (i += 1) {
            const c = self.content[i];
            if (in_quotes) |q| {
                if (c == '\\' and i + 1 < self.content.len) {
                    i += 1;
                    continue;
                }
                if (c == q) {
                    in_quotes = null;
                }
            } else {
                if (c == '"' or c == '\'') {
                    in_quotes = c;
                } else if (c == ',') {
                    self.pos = i + 1;
                    return self.content[pair_start..i];
                }
            }
        }

        self.pos = self.content.len;
        return self.content[pair_start..];
    }
};

fn applyGenericField(ptr: anytype, key: []const u8, val: []const u8) void {
    const PtrType = @TypeOf(ptr);
    const T = switch (@typeInfo(PtrType)) {
        .pointer => |p| p.child,
        else => @compileError("applyGenericField requires a pointer to struct"),
    };

    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (std.mem.eql(u8, field.name, key)) {
            switch (@typeInfo(field.type)) {
                .pointer => |p| {
                    if (p.size == .slice and p.child == u8) {
                        @field(ptr, field.name) = val;
                    }
                },
                .bool => {
                    if (std.mem.eql(u8, val, "true")) {
                        @field(ptr, field.name) = true;
                    } else if (std.mem.eql(u8, val, "false")) {
                        @field(ptr, field.name) = false;
                    }
                },
                .int => {
                    if (std.fmt.parseInt(field.type, val, 10)) |num| {
                        @field(ptr, field.name) = num;
                    } else |_| {}
                },
                .@"enum" => {
                    if (std.meta.stringToEnum(field.type, val)) |e| {
                        @field(ptr, field.name) = e;
                    }
                },
                else => {},
            }
            return;
        }
    }
}

fn isConfigSectionField(name: []const u8) bool {
    inline for (@typeInfo(config_mod.Config).@"struct".fields) |f| {
        if (@typeInfo(f.type) == .@"struct" and std.mem.eql(u8, f.name, name)) {
            return true;
        }
    }
    return false;
}

fn applyValue(config: *config_mod.Config, section: ?[]const u8, key: []const u8, val: []const u8) void {
    if (section) |sec_name| {
        inline for (@typeInfo(config_mod.Config).@"struct".fields) |sec_field| {
            if (std.mem.eql(u8, sec_field.name, sec_name)) {
                if (@typeInfo(sec_field.type) == .@"struct") {
                    applyGenericField(&@field(config, sec_field.name), key, val);
                    return;
                }
            }
        }
    } else {
        applyGenericField(config, key, val);
    }
}

fn lookupEnv(lookup_env: anytype, key: []const u8) ?[]const u8 {
    const T = @TypeOf(lookup_env);
    if (comptime @typeInfo(T) == .pointer and @hasDecl(@typeInfo(T).pointer.child, "get")) {
        return lookup_env.get(key);
    } else if (comptime @typeInfo(T) == .@"struct" and @hasDecl(T, "get")) {
        return lookup_env.get(key);
    } else {
        return lookup_env(key);
    }
}

pub fn resolveConfigPathBuf(
    buf: *[std.fs.max_path_bytes]u8,
    lookup_env: anytype,
) ?[]const u8 {
    if (lookupEnv(lookup_env, platform.env.zap_config)) |custom| {
        if (custom.len > 0) return custom;
    }

    if (lookupEnv(lookup_env, platform.env.xdg_config_home)) |xdg| {
        return platform.joinParts(buf, &.{ xdg, CONFIG_DIR_NAME, DEFAULT_CONFIG_FILE });
    }

    if (platform.is_windows) {
        if (lookupEnv(lookup_env, platform.env.appdata)) |appdata| {
            return platform.joinParts(buf, &.{ appdata, CONFIG_DIR_NAME, DEFAULT_CONFIG_FILE });
        }
    }

    const home = lookupEnv(lookup_env, platform.env.home) orelse lookupEnv(lookup_env, platform.env.userprofile);
    if (home) |h| {
        return platform.joinParts(buf, &.{ h, DOT_CONFIG_DIR, CONFIG_DIR_NAME, DEFAULT_CONFIG_FILE });
    }

    return null;
}

fn firstExistingInParts(
    io: std.Io,
    buf: *[std.fs.max_path_bytes]u8,
    prefix_parts: []const []const u8,
) ?[]const u8 {
    var parts_buf: [4][]const u8 = undefined;
    if (prefix_parts.len + 1 > parts_buf.len) return null;
    @memcpy(parts_buf[0..prefix_parts.len], prefix_parts);

    for (CONFIG_CANDIDATES) |filename| {
        parts_buf[prefix_parts.len] = filename;
        if (platform.joinParts(buf, parts_buf[0 .. prefix_parts.len + 1])) |candidate| {
            if (fs.fileExists(io, candidate)) return candidate;
        }
    }
    return null;
}

pub fn resolveExistingConfigPath(
    io: std.Io,
    buf: *[std.fs.max_path_bytes]u8,
    lookup_env: anytype,
) ?[]const u8 {
    if (lookupEnv(lookup_env, platform.env.zap_config)) |custom| {
        if (custom.len > 0) return custom;
    }

    if (lookupEnv(lookup_env, platform.env.xdg_config_home)) |xdg| {
        if (firstExistingInParts(io, buf, &.{ xdg, CONFIG_DIR_NAME })) |found| return found;
    }

    if (platform.is_windows) {
        if (lookupEnv(lookup_env, platform.env.appdata)) |appdata| {
            if (firstExistingInParts(io, buf, &.{ appdata, CONFIG_DIR_NAME })) |found| return found;
        }
    }

    const home = lookupEnv(lookup_env, platform.env.home) orelse lookupEnv(lookup_env, platform.env.userprofile);
    if (home) |h| {
        if (firstExistingInParts(io, buf, &.{ h, DOT_CONFIG_DIR, CONFIG_DIR_NAME })) |found| return found;
    }

    return resolveConfigPathBuf(buf, lookup_env);
}

test "unit: parse empty string preserves default config" {
    var cfg: config_mod.Config = config_mod.defaultConfig();
    parseToml(&cfg, "");

    try std.testing.expectEqualStrings("~", cfg.directory.home_symbol);
    try std.testing.expectEqualStrings("[❯](bold green)", cfg.character.success_symbol);
    try std.testing.expectEqual(true, cfg.add_newline);
}

test "unit: parse comments, sections and values" {
    const toml_text =
        \\# Configuration comment
        \\add_newline = false
        \\format = "$directory$character"
        \\
        \\[directory]
        \\home_symbol = "<>"
        \\style = "bold yellow"
        \\disabled = true
        \\
        \\[cmd_duration]
        \\min_time = 5000
        \\show_milliseconds = true
        \\
        \\[character]
        \\success_symbol = "[➜](bold green)"
        \\error_symbol = "[X](bold red)"
    ;

    var cfg: config_mod.Config = config_mod.defaultConfig();
    parseToml(&cfg, toml_text);

    try std.testing.expectEqual(false, cfg.add_newline);
    try std.testing.expectEqualStrings("$directory$character", cfg.format);
    try std.testing.expectEqualStrings("<>", cfg.directory.home_symbol);
    try std.testing.expectEqualStrings("bold yellow", cfg.directory.style);
    try std.testing.expectEqual(true, cfg.directory.disabled);
    try std.testing.expectEqual(@as(u64, 5000), cfg.cmd_duration.min_time);
    try std.testing.expectEqual(true, cfg.cmd_duration.show_milliseconds);
    try std.testing.expectEqualStrings("[➜](bold green)", cfg.character.success_symbol);
    try std.testing.expectEqualStrings("[X](bold red)", cfg.character.error_symbol);
}

test "unit: parse git_branch and git_status sections" {
    const toml_text =
        \\[git_branch]
        \\symbol = "󰘬 "
        \\style = "bold purple"
        \\truncation_length = 15
        \\truncation_symbol = "…"
        \\
        \\[git_status]
        \\style = "bold red"
        \\staged = "[+]"
        \\modified = "[!]"
        \\ahead = "UP "
        \\behind = "DOWN "
        \\disabled = false
    ;

    var cfg: config_mod.Config = config_mod.defaultConfig();
    parseToml(&cfg, toml_text);

    try std.testing.expectEqualStrings("󰘬 ", cfg.git_branch.symbol);
    try std.testing.expectEqualStrings("bold purple", cfg.git_branch.style);
    try std.testing.expectEqual(@as(usize, 15), cfg.git_branch.truncation_length);
    try std.testing.expectEqualStrings("…", cfg.git_branch.truncation_symbol);

    try std.testing.expectEqualStrings("bold red", cfg.git_status.style);
    try std.testing.expectEqualStrings("[+]", cfg.git_status.staged);
    try std.testing.expectEqualStrings("[!]", cfg.git_status.modified);
    try std.testing.expectEqualStrings("UP ", cfg.git_status.ahead);
    try std.testing.expectEqualStrings("DOWN ", cfg.git_status.behind);
    try std.testing.expectEqual(false, cfg.git_status.disabled);
}

test "unit: parse git_commit and git_state sections" {
    const toml_text =
        \\[git_commit]
        \\style = "bold green"
        \\commit_hash_length = 8
        \\only_detached = false
        \\tag_symbol = " # "
        \\tag_disabled = false
        \\
        \\[git_state]
        \\style = "bold yellow"
        \\rebase = "REBASE-IN-PROGRESS"
        \\merge = "MERGE-CONFLICT"
        \\disabled = false
    ;

    var cfg: config_mod.Config = config_mod.defaultConfig();
    parseToml(&cfg, toml_text);

    try std.testing.expectEqualStrings("bold green", cfg.git_commit.style);
    try std.testing.expectEqual(@as(usize, 8), cfg.git_commit.commit_hash_length);
    try std.testing.expectEqual(false, cfg.git_commit.only_detached);
    try std.testing.expectEqualStrings(" # ", cfg.git_commit.tag_symbol);
    try std.testing.expectEqual(false, cfg.git_commit.tag_disabled);

    try std.testing.expectEqualStrings("bold yellow", cfg.git_state.style);
    try std.testing.expectEqualStrings("REBASE-IN-PROGRESS", cfg.git_state.rebase);
    try std.testing.expectEqualStrings("MERGE-CONFLICT", cfg.git_state.merge);
    try std.testing.expectEqual(false, cfg.git_state.disabled);
}

test "unit: parse multiline format strings with triple quotes" {
    const multiline_config =
        \\format = """
        \\┌─ $directory
        \\└─ $character"""
        \\
        \\[directory]
        \\style = "bold cyan"
    ;

    var cfg: config_mod.Config = config_mod.defaultConfig();
    parseToml(&cfg, multiline_config);

    const expected_format = "┌─ $directory\n└─ $character";
    try std.testing.expectEqualStrings(expected_format, cfg.format);
    try std.testing.expectEqualStrings("bold cyan", cfg.directory.style);
}

test "unit: parseToml ignores $schema root key" {
    const toml_with_schema =
        \\"$schema" = "https://raw.githubusercontent.com/luth9r/zap/main/zap.schema.json"
        \\
        \\[character]
        \\success_symbol = "[»](bold cyan)"
    ;

    var cfg: config_mod.Config = config_mod.defaultConfig();
    parseToml(&cfg, toml_with_schema);

    try std.testing.expectEqualStrings("[»](bold cyan)", cfg.character.success_symbol);
}

test "unit: resolveConfigPathBuf respects ZAP_CONFIG priority" {
    const mockEnv = struct {
        fn get(key: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, key, "ZAP_CONFIG")) return "/custom/zap.toml";
            if (std.mem.eql(u8, key, "XDG_CONFIG_HOME")) return "/xdg";
            return null;
        }
    }.get;

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = resolveConfigPathBuf(&buf, mockEnv).?;
    try std.testing.expectEqualStrings("/custom/zap.toml", path);
}

test "unit: resolveConfigPathBuf resolves XDG_CONFIG_HOME" {
    const mockEnv = struct {
        fn get(key: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, key, "XDG_CONFIG_HOME")) return "/home/test/.custom_config";
            return null;
        }
    }.get;

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = resolveConfigPathBuf(&buf, mockEnv).?;
    try std.testing.expectEqualStrings(
        "/home/test/.custom_config" ++ platform.sep ++ CONFIG_DIR_NAME ++ platform.sep ++ DEFAULT_CONFIG_FILE,
        path,
    );
}

test "unit: resolveConfigPathBuf falls back to HOME/.config/zap/zap.toml" {
    const mockEnv = struct {
        fn get(key: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, key, "HOME")) return "/home/user";
            return null;
        }
    }.get;

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = resolveConfigPathBuf(&buf, mockEnv).?;
    const expected = "/home/user" ++ platform.sep ++ DOT_CONFIG_DIR ++ platform.sep ++ CONFIG_DIR_NAME ++ platform.sep ++ DEFAULT_CONFIG_FILE;
    try std.testing.expectEqualStrings(expected, path);
}

test "unit: parse os section" {
    const toml_text =
        \\[os]
        \\disabled = false
        \\style = "bold yellow"
        \\symbol = ""
    ;

    var cfg: config_mod.Config = config_mod.defaultConfig();
    parseToml(&cfg, toml_text);

    try std.testing.expectEqual(false, cfg.os.disabled);
    try std.testing.expectEqualStrings("bold yellow", cfg.os.style);
    try std.testing.expectEqualStrings("", cfg.os.symbol);
}

test "unit: parse inline tables in toml" {
    const toml_text =
        \\directory = { truncation_length = 4, home_symbol = "HOME" }
        \\character = { success_symbol = ">>", disabled = true }
    ;

    var cfg: config_mod.Config = config_mod.defaultConfig();
    parseToml(&cfg, toml_text);

    try std.testing.expectEqual(@as(usize, 4), cfg.directory.truncation_length);
    try std.testing.expectEqualStrings("HOME", cfg.directory.home_symbol);
    try std.testing.expectEqualStrings(">>", cfg.character.success_symbol);
    try std.testing.expectEqual(true, cfg.character.disabled);
}

test "unit: parse inline table with commas inside quoted strings" {
    const toml_text =
        \\directory = { format = "[$path](bold, green)", home_symbol = "H,O,M,E", style = "cyan" }
    ;

    var cfg: config_mod.Config = config_mod.defaultConfig();
    parseToml(&cfg, toml_text);

    try std.testing.expectEqualStrings("[$path](bold, green)", cfg.directory.format);
    try std.testing.expectEqualStrings("H,O,M,E", cfg.directory.home_symbol);
    try std.testing.expectEqualStrings("cyan", cfg.directory.style);
}

test "unit: parse inline comments after values while preserving hashes in quotes" {
    const toml_text =
        \\add_newline = false # disable newline
        \\[directory]
        \\truncation_length = 5 # keep 5 segments
        \\style = "#89b4fa bold" # hex color with inline comment
    ;

    var cfg: config_mod.Config = config_mod.defaultConfig();
    parseToml(&cfg, toml_text);

    try std.testing.expectEqual(false, cfg.add_newline);
    try std.testing.expectEqual(@as(usize, 5), cfg.directory.truncation_length);
    try std.testing.expectEqualStrings("#89b4fa bold", cfg.directory.style);
}

test "unit: parse section header and inline table with trailing inline comments" {
    const toml_text =
        \\[directory] # directory section comment
        \\truncation_length = 2
        \\[git_branch] # branch section comment
        \\symbol = "BR "
    ;

    var cfg: config_mod.Config = config_mod.defaultConfig();
    parseToml(&cfg, toml_text);

    try std.testing.expectEqual(@as(usize, 2), cfg.directory.truncation_length);
    try std.testing.expectEqualStrings("BR ", cfg.git_branch.symbol);
}

test "unit: unquoteChecked handles valid, escaped, and single-quote edge cases" {
    try std.testing.expectEqualStrings("hello", unquoteChecked("\"hello\"").?);
    try std.testing.expectEqualStrings("hello", unquoteChecked("'hello'").?);
    try std.testing.expectEqualStrings("a\\\\", unquoteChecked("\"a\\\\\"").?);
    try std.testing.expectEqualStrings("123", unquoteChecked("123").?);
    try std.testing.expectEqualStrings("", unquoteChecked("").?);

    // Unclosed quotes (including single-char quote that previously risked slice-out-of-bounds)
    try std.testing.expect(unquoteChecked("\"") == null);
    try std.testing.expect(unquoteChecked("'") == null);
    try std.testing.expect(unquoteChecked("\"unclosed") == null);
    try std.testing.expect(unquoteChecked("\"escaped\\\"") == null);
}

test "unit: scanToml dispatches sections, pairs, inline tables, and syntax errors" {
    const CountingHandler = struct {
        sections: usize = 0,
        kvs: usize = 0,
        inline_kvs: usize = 0,
        syntax_errors: usize = 0,
        inline_errors: usize = 0,

        pub fn onSection(self: *@This(), _: usize, _: []const u8) !void {
            self.sections += 1;
        }
        pub fn onKeyValue(self: *@This(), _: usize, _: ?[]const u8, _: []const u8, _: []const u8) !void {
            self.kvs += 1;
        }
        pub fn onInlineKeyValue(self: *@This(), _: usize, _: []const u8, _: []const u8, _: []const u8) !void {
            self.inline_kvs += 1;
        }
        pub fn onSyntaxError(self: *@This(), _: usize, _: TomlSyntaxError, _: []const u8) !void {
            self.syntax_errors += 1;
        }
        pub fn onInlineError(self: *@This(), _: usize, _: []const u8, _: TomlInlineError, _: []const u8) !void {
            self.inline_errors += 1;
        }
    };

    const sample =
        \\format = "$directory"
        \\[directory]
        \\style = "bold cyan"
        \\character = { success_symbol = "OK", bad_pair }
        \\broken_line
    ;

    var handler = CountingHandler{};
    try scanToml(sample, &handler);

    try std.testing.expectEqual(@as(usize, 1), handler.sections);
    try std.testing.expectEqual(@as(usize, 2), handler.kvs);
    try std.testing.expectEqual(@as(usize, 1), handler.inline_kvs);
    try std.testing.expectEqual(@as(usize, 1), handler.inline_errors);
    try std.testing.expectEqual(@as(usize, 1), handler.syntax_errors);
}
