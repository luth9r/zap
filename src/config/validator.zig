const std = @import("std");
const registry = @import("../modules/registry.zig");
const module_pkg = @import("../modules/module.zig");
const style_mod = @import("../engine/style.zig");
const toml_parser = @import("toml_parser.zig");

pub const ValidationResult = struct {
    error_count: usize = 0,
    warning_count: usize = 0,

    pub fn isValid(self: ValidationResult) bool {
        return self.error_count == 0;
    }
};

/// Validates a format string for matching brackets/parentheses, known variables, and valid ANSI styles.
pub fn validateFormatString(
    writer: anytype,
    format: []const u8,
    file_display: []const u8,
    line_num: usize,
    context_desc: []const u8,
    comptime allowed_vars: []const []const u8,
    res: *ValidationResult,
) !void {
    var i: usize = 0;
    var bracket_depth: isize = 0;
    var paren_depth: isize = 0;

    while (i < format.len) {
        if (format[i] == '\\' and i + 1 < format.len) {
            i += 2;
            continue;
        }

        if (format[i] == '[') {
            bracket_depth += 1;
            // Check for styled group `[content](style)`
            if (findMatchingBracket(format, i)) |close_bracket| {
                if (close_bracket + 1 < format.len and format[close_bracket + 1] == '(') {
                    if (findMatchingParen(format, close_bracket + 1)) |close_paren| {
                        const style_spec = format[close_bracket + 2 .. close_paren];
                        const trimmed_style = std.mem.trim(u8, style_spec, " \t");
                        // If style is not a variable reference like $style or $custom_style
                        if (!std.mem.startsWith(u8, trimmed_style, "$")) {
                            if (style_mod.Style.validate(trimmed_style)) |invalid_token| {
                                try writer.print("✖ Error [{s}:{d}]: invalid style '{s}' in {s}: unknown token '{s}'\n", .{
                                    file_display,
                                    line_num,
                                    trimmed_style,
                                    context_desc,
                                    invalid_token,
                                });
                                res.error_count += 1;
                            }
                        }
                    } else {
                        try writer.print("✖ Error [{s}:{d}]: unclosed style parentheses in {s} starting at '({s}'\n", .{
                            file_display,
                            line_num,
                            context_desc,
                            format[close_bracket + 1 .. @min(format.len, close_bracket + 20)],
                        });
                        res.error_count += 1;
                    }
                }
            }
        } else if (format[i] == ']') {
            bracket_depth -= 1;
            if (bracket_depth < 0) {
                try writer.print("✖ Error [{s}:{d}]: unexpected closing bracket ']' in {s}\n", .{
                    file_display,
                    line_num,
                    context_desc,
                });
                res.error_count += 1;
                bracket_depth = 0;
            }
        } else if (format[i] == '(') {
            paren_depth += 1;
        } else if (format[i] == ')') {
            paren_depth -= 1;
            if (paren_depth < 0) {
                try writer.print("✖ Error [{s}:{d}]: unexpected closing parenthesis ')' in {s}\n", .{
                    file_display,
                    line_num,
                    context_desc,
                });
                res.error_count += 1;
                paren_depth = 0;
            }
        } else if (format[i] == '$') {
            const var_name = extractVarName(format[i + 1 ..]);
            if (var_name.len > 0) {
                var is_known = false;
                for (allowed_vars) |v| {
                    if (std.mem.eql(u8, var_name, v)) {
                        is_known = true;
                        break;
                    }
                }
                if (!is_known) {
                    try writer.print("✖ Error [{s}:{d}]: unknown variable '${s}' in {s}\n", .{
                        file_display,
                        line_num,
                        var_name,
                        context_desc,
                    });
                    res.error_count += 1;
                }
                i += 1 + var_name.len;
                continue;
            }
        }

        i += 1;
    }

    if (bracket_depth > 0) {
        try writer.print("✖ Error [{s}:{d}]: unclosed bracket '[' in {s}\n", .{
            file_display,
            line_num,
            context_desc,
        });
        res.error_count += 1;
    }
    if (paren_depth > 0) {
        try writer.print("✖ Error [{s}:{d}]: unclosed parenthesis '(' in {s}\n", .{
            file_display,
            line_num,
            context_desc,
        });
        res.error_count += 1;
    }
}

fn findMatchingBracket(str: []const u8, start_idx: usize) ?usize {
    var depth: usize = 0;
    var i: usize = start_idx;
    while (i < str.len) {
        if (str[i] == '\\' and i + 1 < str.len) {
            i += 2;
            continue;
        }
        if (str[i] == '[') depth += 1;
        if (str[i] == ']') {
            depth -= 1;
            if (depth == 0) return i;
        }
        i += 1;
    }
    return null;
}

fn findMatchingParen(str: []const u8, start_idx: usize) ?usize {
    var depth: usize = 0;
    var i: usize = start_idx;
    while (i < str.len) {
        if (str[i] == '\\' and i + 1 < str.len) {
            i += 2;
            continue;
        }
        if (str[i] == '(') depth += 1;
        if (str[i] == ')') {
            depth -= 1;
            if (depth == 0) return i;
        }
        i += 1;
    }
    return null;
}

fn extractVarName(slice: []const u8) []const u8 {
    var len: usize = 0;
    while (len < slice.len) : (len += 1) {
        const c = slice[len];
        if (std.ascii.isAlphanumeric(c) or c == '_') {
            continue;
        }
        break;
    }
    return slice[0..len];
}

const root_allowed_modules = blk: {
    const decls = @typeInfo(registry).@"struct".decls;
    var list: [decls.len][]const u8 = undefined;
    for (decls, 0..) |d, idx| {
        list[idx] = d.name;
    }
    break :blk list;
};


/// Validates TOML content directly on the stack with zero heap allocations.
pub fn validateContent(
    writer: anytype,
    content: []const u8,
    file_display: []const u8,
) !ValidationResult {
    var res = ValidationResult{};
    var line_it = std.mem.splitScalar(u8, content, '\n');
    var line_num: usize = 0;
    var current_section: ?[]const u8 = null;

    while (line_it.next()) |raw_line| {
        line_num += 1;
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        // Section header check
        if (line[0] == '[') {
            if (line.len < 2 or line[line.len - 1] != ']') {
                try writer.print("✖ Error [{s}:{d}]: unclosed section header '{s}'\n", .{
                    file_display,
                    line_num,
                    line,
                });
                res.error_count += 1;
                continue;
            }

            const sec_name = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
            if (sec_name.len == 0) {
                try writer.print("✖ Error [{s}:{d}]: empty section header '[]'\n", .{
                    file_display,
                    line_num,
                });
                res.error_count += 1;
                continue;
            }

            // Check if section name is registered module
            var is_registered_section = false;
            inline for (@typeInfo(registry).@"struct".decls) |decl| {
                if (std.mem.eql(u8, sec_name, decl.name)) {
                    is_registered_section = true;
                }
            }

            if (!is_registered_section) {
                try writer.print("✖ Error [{s}:{d}]: unknown section '[{s}]'\n", .{
                    file_display,
                    line_num,
                    sec_name,
                });
                res.error_count += 1;
            }

            current_section = sec_name;
            continue;
        }

        // Key-value pair check
        const equal_idx_opt = std.mem.indexOfScalar(u8, line, '=');
        if (equal_idx_opt == null) {
            try writer.print("✖ Error [{s}:{d}]: syntax error, expected 'key = value', got '{s}'\n", .{
                file_display,
                line_num,
                line,
            });
            res.error_count += 1;
            continue;
        }

        const equal_idx = equal_idx_opt.?;
        var key = std.mem.trim(u8, line[0..equal_idx], " \t");
        var val = std.mem.trim(u8, line[equal_idx + 1 ..], " \t");

        if (key.len >= 2 and key[0] == '"' and key[key.len - 1] == '"') {
            key = key[1 .. key.len - 1];
        }

        // Handle multiline strings
        if (val.len >= 3 and (std.mem.startsWith(u8, val, "\"\"\"") or std.mem.startsWith(u8, val, "'''"))) {
            val = toml_parser.extractMultilineValue(val, content, &line_it);
        } else {
            // Check for unclosed single-line quotes
            if (val.len > 0) {
                const quote_char = val[0];
                if (quote_char == '"' or quote_char == '\'') {
                    if (val.len < 2 or val[val.len - 1] != quote_char) {
                        try writer.print("✖ Error [{s}:{d}]: unclosed quote in value for '{s}'\n", .{
                            file_display,
                            line_num,
                            key,
                        });
                        res.error_count += 1;
                        continue;
                    }
                    val = val[1 .. val.len - 1];
                }
            }
        }

        // Validate key and value
        if (current_section) |sec| {
            try validateSectionProperty(writer, sec, key, val, file_display, line_num, &res);
        } else {
            try validateRootProperty(writer, key, val, file_display, line_num, &res);
        }
    }

    return res;
}

fn validateRootProperty(
    writer: anytype,
    key: []const u8,
    val: []const u8,
    file_display: []const u8,
    line_num: usize,
    res: *ValidationResult,
) !void {
    if (std.mem.eql(u8, key, "$schema")) return;

    if (std.mem.eql(u8, key, "add_newline")) {
        if (!std.mem.eql(u8, val, "true") and !std.mem.eql(u8, val, "false")) {
            try writer.print("✖ Error [{s}:{d}]: invalid boolean for 'add_newline': expected 'true' or 'false', got '{s}'\n", .{
                file_display,
                line_num,
                val,
            });
            res.error_count += 1;
        }
        return;
    }

    if (std.mem.eql(u8, key, "format")) {
        try validateFormatString(
            writer,
            val,
            file_display,
            line_num,
            "root format",
            &root_allowed_modules,
            res,
        );
        return;
    }

    // Check if user accidentally put a module table inline at root (e.g. `directory = ...`)
    inline for (@typeInfo(registry).@"struct".decls) |decl| {
        if (std.mem.eql(u8, key, decl.name)) {
            try writer.print("⚠ Warning [{s}:{d}]: '{s}' specified at root level; did you mean '[{s}]'?\n", .{
                file_display,
                line_num,
                key,
                key,
            });
            res.warning_count += 1;
            return;
        }
    }

    try writer.print("✖ Error [{s}:{d}]: unknown root property '{s}'\n", .{
        file_display,
        line_num,
        key,
    });
    res.error_count += 1;
}

fn validateSectionProperty(
    writer: anytype,
    section: []const u8,
    key: []const u8,
    val: []const u8,
    file_display: []const u8,
    line_num: usize,
    res: *ValidationResult,
) !void {
    inline for (@typeInfo(registry).@"struct".decls) |decl| {
        if (std.mem.eql(u8, section, decl.name)) {
            const Mod = @field(registry, decl.name);
            const CfgType = comptime module_pkg.resolveConfigType(Mod).?;

            var field_found = false;
            inline for (@typeInfo(CfgType).@"struct".fields) |f| {
                if (std.mem.eql(u8, key, f.name)) {
                    field_found = true;
                    // Type-specific validation
                    switch (@typeInfo(f.type)) {
                        .bool => {
                            if (!std.mem.eql(u8, val, "true") and !std.mem.eql(u8, val, "false")) {
                                try writer.print("✖ Error [{s}:{d}]: invalid boolean for '{s}' in [{s}]: expected 'true' or 'false', got '{s}'\n", .{
                                    file_display,
                                    line_num,
                                    key,
                                    section,
                                    val,
                                });
                                res.error_count += 1;
                            }
                        },
                        .int => {
                            if (std.fmt.parseInt(f.type, val, 10)) |_| {} else |_| {
                                try writer.print("✖ Error [{s}:{d}]: invalid integer for '{s}' in [{s}]: '{s}'\n", .{
                                    file_display,
                                    line_num,
                                    key,
                                    section,
                                    val,
                                });
                                res.error_count += 1;
                            }
                        },
                        .@"enum" => {
                            if (std.meta.stringToEnum(f.type, val) == null) {
                                try writer.print("✖ Error [{s}:{d}]: invalid enum variant for '{s}' in [{s}]: '{s}'\n", .{
                                    file_display,
                                    line_num,
                                    key,
                                    section,
                                    val,
                                });
                                res.error_count += 1;
                            }
                        },
                        .pointer => |p| {
                            if (p.size == .slice and p.child == u8) {
                                if (std.mem.eql(u8, key, "style") or std.mem.endsWith(u8, key, "_style")) {
                                    if (style_mod.Style.validate(val)) |invalid_token| {
                                        try writer.print("✖ Error [{s}:{d}]: invalid style for '{s}' in [{s}]: unknown token '{s}'\n", .{
                                            file_display,
                                            line_num,
                                            key,
                                            section,
                                            invalid_token,
                                        });
                                        res.error_count += 1;
                                    }
                                } else if (std.mem.eql(u8, key, "format")) {
                                    // Validate module format string with module variables
                                    const mod_vars = comptime blk: {
                                        if (@hasDecl(Mod, "Var")) {
                                            const var_fields = @typeInfo(Mod.Var).@"enum".fields;
                                            var names: [var_fields.len + 1][]const u8 = undefined;
                                            for (var_fields, 0..) |vf, idx| {
                                                names[idx] = vf.name;
                                            }
                                            names[var_fields.len] = "style";
                                            break :blk names;
                                        } else {
                                            break :blk [_][]const u8{"style"};
                                        }
                                    };

                                    var desc_buf: [64]u8 = undefined;
                                    const desc = std.fmt.bufPrint(&desc_buf, "[{s}] format", .{section}) catch "module format";
                                    try validateFormatString(
                                        writer,
                                        val,
                                        file_display,
                                        line_num,
                                        desc,
                                        &mod_vars,
                                        res,
                                    );
                                }
                            }
                        },
                        else => {},
                    }
                    return;
                }
            }

            if (!field_found) {
                try writer.print("✖ Error [{s}:{d}]: unknown property '{s}' in section '[{s}]'\n", .{
                    file_display,
                    line_num,
                    key,
                    section,
                });
                res.error_count += 1;
            }
            return;
        }
    }
}

/// Validates a configuration file on disk.
pub fn validateFile(
    io: std.Io,
    path: []const u8,
    writer: anytype,
) !ValidationResult {
    const file = if (std.fs.path.isAbsolute(path))
        std.Io.Dir.openFileAbsolute(io, path, .{}) catch |err| {
            try writer.print("✖ Error: failed to open config file '{s}': {any}\n", .{ path, err });
            return ValidationResult{ .error_count = 1 };
        }
    else
        std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| {
            try writer.print("✖ Error: failed to open config file '{s}': {any}\n", .{ path, err });
            return ValidationResult{ .error_count = 1 };
        };
    defer file.close(io);

    var content_buf: [64 * 1024]u8 = undefined;
    var stream_buf: [4096]u8 = undefined;
    var reader = file.reader(io, &stream_buf);

    const bytes_read = reader.interface.readSliceShort(&content_buf) catch |err| {
        try writer.print("✖ Error: failed to read config file '{s}': {any}\n", .{ path, err });
        return ValidationResult{ .error_count = 1 };
    };

    const res = try validateContent(writer, content_buf[0..bytes_read], path);

    if (res.isValid() and res.warning_count == 0) {
        try writer.print("✔ Configuration '{s}' is valid.\n", .{path});
    } else if (res.isValid() and res.warning_count > 0) {
        try writer.print("⚠ Configuration '{s}' is valid with {d} warning(s).\n", .{ path, res.warning_count });
    } else {
        try writer.print("\n✖ Validation failed for '{s}': {d} error(s), {d} warning(s).\n", .{ path, res.error_count, res.warning_count });
    }

    return res;
}

const BufferWriter = @import("../utils/buffer_writer.zig").BufferWriter;

test "unit: validateContent with valid configuration" {
    var out_buf: [2048]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&out_buf, &pos);
    const valid_toml =
        \\add_newline = true
        \\format = "$directory$git_branch$character"
        \\
        \\[directory]
        \\style = "bold cyan"
        \\truncation_length = 4
        \\
        \\[character]
        \\success_symbol = "[❯](bold green)"
    ;

    const res = try validateContent(writer, valid_toml, "test.toml");
    try std.testing.expect(res.isValid());
    try std.testing.expectEqual(@as(usize, 0), res.error_count);
    try std.testing.expectEqual(@as(usize, 0), res.warning_count);
}

test "unit: validateContent catches unknown section and properties" {
    var out_buf: [4096]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&out_buf, &pos);
    const invalid_toml =
        \\[unknown_section]
        \\foo = "bar"
        \\
        \\[directory]
        \\non_existent_key = 123
        \\disabled = "not_a_bool"
    ;

    const res = try validateContent(writer, invalid_toml, "test.toml");
    try std.testing.expect(!res.isValid());
    // 1 unknown section, 1 unknown property, 1 invalid bool
    try std.testing.expect(res.error_count >= 3);
}

test "unit: validateContent catches invalid style and format errors" {
    var out_buf: [4096]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&out_buf, &pos);
    const invalid_toml =
        \\format = "$directory$unknown_module"
        \\
        \\[directory]
        \\style = "bold invalidcolor"
        \\format = "[$path](bold red"
    ;

    const res = try validateContent(writer, invalid_toml, "test.toml");
    try std.testing.expect(!res.isValid());
    // $unknown_module, invalidcolor, unclosed bracket/paren
    try std.testing.expect(res.error_count >= 3);
}


