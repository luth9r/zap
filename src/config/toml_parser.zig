const std = @import("std");
const builtin = @import("builtin");
const config_mod = @import("config.zig");

pub fn loadConfigFile(
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    config: *config_mod.Config,
    content_buf: []u8,
) void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const config_path = resolveExistingConfigPath(io, &path_buf, environ_map) orelse return;

    const file = if (std.fs.path.isAbsolute(config_path))
        std.Io.Dir.openFileAbsolute(io, config_path, .{}) catch return
    else
        std.Io.Dir.cwd().openFile(io, config_path, .{}) catch return;
    defer file.close(io);

    var stream_buf: [4096]u8 = undefined;
    var file_reader = file.reader(io, &stream_buf);

    const bytes_read = file_reader.interface.readSliceShort(content_buf) catch return;
    if (bytes_read == 0) return;

    parseToml(config, content_buf[0..bytes_read]);
}

/// Parses a section header `[section]` if the line is a section declaration.
fn parseSectionHeader(line: []const u8) ?[]const u8 {
    if (line.len >= 2 and line[0] == '[' and line[line.len - 1] == ']') {
        return std.mem.trim(u8, line[1 .. line.len - 1], " \t");
    }
    return null;
}

/// Unquotes simple double- or single-quoted string values.
fn unquoteValue(val: []const u8) []const u8 {
    if (val.len >= 2 and ((val[0] == '"' and val[val.len - 1] == '"') or (val[0] == '\'' and val[val.len - 1] == '\''))) {
        return val[1 .. val.len - 1];
    }
    return val;
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

/// Parses TOML content directly into Config without heap allocations using comptime reflection.
pub fn parseToml(config: *config_mod.Config, content: []const u8) void {
    var line_it = std.mem.splitScalar(u8, content, '\n');
    var current_section: ?[]const u8 = null;

    while (line_it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        if (parseSectionHeader(line)) |sec| {
            current_section = sec;
            continue;
        }

        if (std.mem.indexOfScalar(u8, line, '=')) |equal_idx| {
            var key = std.mem.trim(u8, line[0..equal_idx], " \t");
            var val = std.mem.trim(u8, line[equal_idx + 1 ..], " \t");

            if (key.len >= 2 and key[0] == '"' and key[key.len - 1] == '"') {
                key = key[1 .. key.len - 1];
            }

            if (std.mem.eql(u8, key, "$schema")) continue;

            // Support TOML inline tables: key = { k1 = "v1", k2 = 123 }
            if (val.len >= 2 and val[0] == '{' and val[val.len - 1] == '}') {
                const inner = std.mem.trim(u8, val[1 .. val.len - 1], " \t\r");
                const target_sec = if (current_section) |s| s else key;
                parseInlineTable(config, target_sec, inner);
                continue;
            }

            if (val.len >= 3 and (std.mem.startsWith(u8, val, "\"\"\"") or std.mem.startsWith(u8, val, "'''"))) {
                val = extractMultilineValue(val, content, &line_it);
            } else {
                val = unquoteValue(val);
            }

            applyValue(config, current_section, key, val);
        }
    }
}

fn parseInlineTable(config: *config_mod.Config, target_section: []const u8, content_inside: []const u8) void {
    var pair_start: usize = 0;
    var i: usize = 0;
    var in_quotes: ?u8 = null;

    while (i < content_inside.len) : (i += 1) {
        const c = content_inside[i];
        if (in_quotes) |q| {
            if (c == '\\' and i + 1 < content_inside.len) {
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
                parseAndApplyPair(config, target_section, content_inside[pair_start..i]);
                pair_start = i + 1;
            }
        }
    }

    if (pair_start < content_inside.len) {
        parseAndApplyPair(config, target_section, content_inside[pair_start..]);
    }
}

fn parseAndApplyPair(config: *config_mod.Config, target_section: []const u8, item: []const u8) void {
    const trimmed_item = std.mem.trim(u8, item, " \t\r");
    if (trimmed_item.len == 0) return;
    if (std.mem.indexOfScalar(u8, trimmed_item, '=')) |eq_idx| {
        var k = std.mem.trim(u8, trimmed_item[0..eq_idx], " \t");
        var v = std.mem.trim(u8, trimmed_item[eq_idx + 1 ..], " \t");
        if (k.len >= 2 and k[0] == '"' and k[k.len - 1] == '"') {
            k = k[1 .. k.len - 1];
        }
        v = unquoteValue(v);
        applyValue(config, target_section, k, v);
    }
}

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
    // User-defined configuration path via environment variable
    if (lookupEnv(lookup_env, "ZAP_CONFIG")) |custom| {
        return custom;
    }

    // XDG Base Directory Specification support ($XDG_CONFIG_HOME/zap/zap.toml)
    if (lookupEnv(lookup_env, "XDG_CONFIG_HOME")) |xdg| {
        return std.fmt.bufPrint(buf, "{s}/zap/zap.toml", .{xdg}) catch null;
    }

    // Windows-specific configuration path support (%APPDATA%\zap\zap.toml)
    if (builtin.os.tag == .windows) {
        if (lookupEnv(lookup_env, "APPDATA")) |appdata| {
            return std.fmt.bufPrint(buf, "{s}\\zap\\zap.toml", .{appdata}) catch null;
        }
    }

    // Universal fallback (~/.config/zap/zap.toml)
    const home_env = if (builtin.os.tag == .windows) "USERPROFILE" else "HOME";
    if (lookupEnv(lookup_env, home_env)) |home| {
        const sep = if (builtin.os.tag == .windows) "\\" else "/";
        return std.fmt.bufPrint(buf, "{s}{s}.config{s}zap{s}zap.toml", .{ home, sep, sep, sep }) catch null;
    }

    return null;
}

pub fn resolveExistingConfigPath(
    io: std.Io,
    buf: *[std.fs.max_path_bytes]u8,
    lookup_env: anytype,
) ?[]const u8 {
    if (lookupEnv(lookup_env, "ZAP_CONFIG")) |custom| {
        return custom;
    }

    const candidates = [_][]const u8{ "zap.toml", "config.toml" };

    if (lookupEnv(lookup_env, "XDG_CONFIG_HOME")) |xdg| {
        for (candidates) |filename| {
            if (std.fmt.bufPrint(buf, "{s}/zap/{s}", .{ xdg, filename })) |candidate| {
                if (std.Io.Dir.openFileAbsolute(io, candidate, .{})) |f| {
                    var file = f;
                    file.close(io);
                    return candidate;
                } else |_| {}
            } else |_| {}
        }
    }

    if (builtin.os.tag == .windows) {
        if (lookupEnv(lookup_env, "APPDATA")) |appdata| {
            for (candidates) |filename| {
                if (std.fmt.bufPrint(buf, "{s}\\zap\\{s}", .{ appdata, filename })) |candidate| {
                    if (std.Io.Dir.openFileAbsolute(io, candidate, .{})) |f| {
                        var file = f;
                        file.close(io);
                        return candidate;
                    } else |_| {}
                } else |_| {}
            }
        }
    }

    const home_env = if (builtin.os.tag == .windows) "USERPROFILE" else "HOME";
    if (lookupEnv(lookup_env, home_env)) |home| {
        const sep = if (builtin.os.tag == .windows) "\\" else "/";
        for (candidates) |filename| {
            if (std.fmt.bufPrint(buf, "{s}{s}.config{s}zap{s}{s}", .{ home, sep, sep, sep, filename })) |candidate| {
                if (std.Io.Dir.openFileAbsolute(io, candidate, .{})) |f| {
                    var file = f;
                    file.close(io);
                    return candidate;
                } else |_| {}
            } else |_| {}
        }
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
    try std.testing.expectEqualStrings("/home/test/.custom_config/zap/zap.toml", path);
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
    try std.testing.expectEqualStrings("/home/user/.config/zap/zap.toml", path);
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

