const std = @import("std");
const testing = std.testing;
const style_mod = @import("style.zig");

pub fn Variable(comptime EnumType: type) type {
    return struct {
        name: EnumType,
        value: []const u8,
    };
}

pub const Shell = @import("../init/root.zig").Shell;

pub const EmptyVar = enum {};
pub const EmptyContext = FormatContext(EmptyVar);

/// Holds variable bindings and styling options for template expansion.
pub fn FormatContext(comptime EnumType: type) type {
    return struct {
        /// Array of key-value pairs available for expansion (e.g. `$path`, `$symbol`).
        vars: []const Variable(EnumType) = &.{},
        /// Default style used when `$style` is referenced within a format group.
        style: []const u8 = "",
        /// Shell target for zero-width escape wrapping.
        shell: Shell = .generic,

        /// Looks up a variable by its name. Checks `$style` first, then searches `vars`.
        pub fn get(self: @This(), name_str: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, name_str, "style")) {
                if (self.style.len > 0) return self.style;
                return null;
            }
            const name = std.meta.stringToEnum(EnumType, name_str) orelse return null;
            for (self.vars) |v| {
                if (v.name == name) {
                    return v.value;
                }
            }
            return null;
        }
    };
}

/// Formats a style template string using the provided variable context.
///
/// Expands `$variable` placeholders, handles conditional groups like `($version )`,
/// and applies ANSI color styles to `[content](style)` blocks.
///
/// Arguments:
/// - `writer`: Any streaming writer implementing writeByte and writeAll.
/// - `template`: Format string template (e.g. `"[$symbol]($style) in [$path](cyan)"`).
/// - `ctx`: Context supplying variable values and module styles.
pub fn formatTemplateWriter(
    writer: anytype,
    template: []const u8,
    ctx: anytype,
) !void {
    var i: usize = 0;
    while (i < template.len) {
        if (template[i] == '\\' and i + 1 < template.len) {
            const esc = template[i + 1];
            if (esc == 'n') {
                try writer.writeByte('\n');
            } else if (esc == 't') {
                try writer.writeByte('\t');
            } else if (esc == 'r') {
                try writer.writeByte('\r');
            } else {
                try writer.writeByte(esc);
            }
            i += 2;
            continue;
        }
        if (template[i] == '(') {
            if (parseConditionalGroup(template, i)) |cond| {
                if (shouldRenderConditionalGroup(cond.inner, ctx)) {
                    try formatTemplateWriter(writer, cond.inner, ctx);
                }
                i = cond.next_index;
                continue;
            }
        }
        if (template[i] == '[') {
            if (parseStyledGroup(template, i)) |group| {
                try renderStyledGroup(writer, group.content, group.style_spec, ctx);
                i = group.next_index;
                continue;
            }
        }
        if (template[i] == '$') {
            const var_name = extractVarName(template[i + 1 ..]);
            if (var_name.len > 0) {
                if (ctx.get(var_name)) |val| {
                    try writer.writeAll(val);
                }
                i += 1 + var_name.len;
                continue;
            }
        }
        try writer.writeByte(template[i]);
        i += 1;
    }
}

/// Note: used exclusively for unit tests. In runtime, formatTemplateWriter is used with stack-based BufferWriter (zero heap allocations).
pub fn formatTemplate(
    allocator: std.mem.Allocator,
    template: []const u8,
    ctx: anytype,
) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    const OutWriter = struct {
        list: *std.ArrayList(u8),
        alloc: std.mem.Allocator,

        pub fn writeByte(self: @This(), byte: u8) !void {
            try self.list.append(self.alloc, byte);
        }

        pub fn writeAll(self: @This(), bytes: []const u8) !void {
            try self.list.appendSlice(self.alloc, bytes);
        }
    };

    const writer = OutWriter{ .list = &out, .alloc = allocator };
    try formatTemplateWriter(writer, template, ctx);

    return try out.toOwnedSlice(allocator);
}

const StyledGroup = struct {
    content: []const u8,
    style_spec: []const u8,
    next_index: usize,
};

fn parseStyledGroup(template: []const u8, start_idx: usize) ?StyledGroup {
    if (template[start_idx] != '[') return null;

    // Find closing ']' taking escapes into account
    var i: usize = start_idx + 1;
    var bracket_depth: usize = 1;
    var close_bracket_idx: ?usize = null;

    while (i < template.len) {
        if (template[i] == '\\' and i + 1 < template.len) {
            i += 2;
            continue;
        }
        if (template[i] == '[') {
            bracket_depth += 1;
        } else if (template[i] == ']') {
            bracket_depth -= 1;
            if (bracket_depth == 0) {
                close_bracket_idx = i;
                break;
            }
        }
        i += 1;
    }

    const close_bracket = close_bracket_idx orelse return null;

    // Must be immediately followed by '('
    if (close_bracket + 1 >= template.len or template[close_bracket + 1] != '(') {
        return null;
    }

    // Find closing ')'
    var j: usize = close_bracket + 2;
    var paren_depth: usize = 1;
    var close_paren_idx: ?usize = null;

    while (j < template.len) {
        if (template[j] == '\\' and j + 1 < template.len) {
            j += 2;
            continue;
        }
        if (template[j] == '(') {
            paren_depth += 1;
        } else if (template[j] == ')') {
            paren_depth -= 1;
            if (paren_depth == 0) {
                close_paren_idx = j;
                break;
            }
        }
        j += 1;
    }

    const close_paren = close_paren_idx orelse return null;

    return StyledGroup{
        .content = template[start_idx + 1 .. close_bracket],
        .style_spec = template[close_bracket + 2 .. close_paren],
        .next_index = close_paren + 1,
    };
}

/// Renders a single styled group `[content](style)` directly into the output buffer.
fn renderStyledGroup(
    writer: anytype,
    content_raw: []const u8,
    style_spec: []const u8,
    ctx: anytype,
) !void {
    if (isGroupContentEmpty(content_raw, ctx)) return;

    var resolved_style = style_spec;
    const trimmed_spec = std.mem.trim(u8, style_spec, " \t");
    if (std.mem.startsWith(u8, trimmed_spec, "$")) {
        if (ctx.get(trimmed_spec[1..])) |val| {
            resolved_style = val;
        } else if (std.mem.eql(u8, trimmed_spec, "$style")) {
            resolved_style = ctx.style;
        }
    }

    var style_buf: [64]u8 = undefined;
    const style_ansi = if (std.mem.startsWith(u8, resolved_style, "\x1b["))
        resolved_style
    else
        style_mod.renderStyleBuf(&style_buf, resolved_style) orelse "";

    if (style_ansi.len > 0)
        try writeZeroWidthAnsi(writer, style_ansi, ctx.shell);

    try renderGroupContent(writer, content_raw, ctx);

    if (style_ansi.len > 0)
        try writeZeroWidthAnsi(writer, "\x1b[0m", ctx.shell);
}

pub fn writeZeroWidthAnsi(writer: anytype, ansi_seq: []const u8, shell: Shell) !void {
    switch (shell) {
        .bash => {
            try writer.writeByte('\x01');
            try writer.writeAll(ansi_seq);
            try writer.writeByte('\x02');
        },
        .zsh => {
            try writer.writeAll("%{");
            try writer.writeAll(ansi_seq);
            try writer.writeAll("%}");
        },
        .fish, .powershell, .generic => {
            try writer.writeAll(ansi_seq);
        },
    }
}

fn isGroupContentEmpty(raw: []const u8, ctx: anytype) bool {
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '\\' and i + 1 < raw.len) {
            return false;
        }
        if (raw[i] == '(') {
            if (parseConditionalGroup(raw, i)) |cond| {
                if (!isGroupContentEmpty(cond.inner, ctx)) return false;
                i = cond.next_index;
                continue;
            }
        }
        if (raw[i] == '$') {
            const var_name = extractVarName(raw[i + 1 ..]);
            if (var_name.len > 0) {
                if (ctx.get(var_name)) |val| {
                    if (val.len > 0) return false;
                }
                i += 1 + var_name.len;
                continue;
            }
        }
        return false;
    }
    return true;
}

fn renderGroupContent(
    writer: anytype,
    raw: []const u8,
    ctx: anytype,
) !void {
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '\\' and i + 1 < raw.len) {
            const esc = raw[i + 1];
            if (esc == 'n') {
                try writer.writeByte('\n');
            } else if (esc == 't') {
                try writer.writeByte('\t');
            } else if (esc == 'r') {
                try writer.writeByte('\r');
            } else {
                try writer.writeByte(esc);
            }
            i += 2;
            continue;
        }

        // Conditional group: (content with $var)
        if (raw[i] == '(') {
            if (parseConditionalGroup(raw, i)) |cond| {
                if (shouldRenderConditionalGroup(cond.inner, ctx)) {
                    try renderGroupContent(writer, cond.inner, ctx);
                }
                i = cond.next_index;
                continue;
            }
        }

        if (raw[i] == '$') {
            const var_name = extractVarName(raw[i + 1 ..]);
            if (var_name.len > 0) {
                if (ctx.get(var_name)) |val| {
                    try writer.writeAll(val);
                }
                i += 1 + var_name.len;
                continue;
            }
        }

        try writer.writeByte(raw[i]);
        i += 1;
    }
}

fn shouldRenderConditionalGroup(inner: []const u8, ctx: anytype) bool {
    var has_var = false;
    var all_vars_empty = true;
    var i: usize = 0;
    while (i < inner.len) {
        if (inner[i] == '\\' and i + 1 < inner.len) {
            i += 2;
            continue;
        }
        if (inner[i] == '$') {
            const var_name = extractVarName(inner[i + 1 ..]);
            if (var_name.len > 0) {
                has_var = true;
                if (ctx.get(var_name)) |val| {
                    if (val.len > 0) {
                        all_vars_empty = false;
                    }
                }
                i += 1 + var_name.len;
                continue;
            }
        }
        i += 1;
    }
    if (has_var and all_vars_empty) return false;
    return true;
}

const ConditionalGroup = struct {
    inner: []const u8,
    next_index: usize,
};

fn containsVarOrStyled(inner: []const u8) bool {
    var i: usize = 0;
    while (i < inner.len) : (i += 1) {
        if (inner[i] == '\\' and i + 1 < inner.len) {
            i += 1;
            continue;
        }
        if (inner[i] == '$' or inner[i] == '[') return true;
    }
    return false;
}

fn parseConditionalGroup(raw: []const u8, start_idx: usize) ?ConditionalGroup {
    if (raw[start_idx] != '(') return null;

    var i: usize = start_idx + 1;
    var depth: usize = 1;

    while (i < raw.len) {
        if (raw[i] == '\\' and i + 1 < raw.len) {
            i += 2;
            continue;
        }
        if (raw[i] == '(') {
            depth += 1;
        } else if (raw[i] == ')') {
            depth -= 1;
            if (depth == 0) {
                const inner = raw[start_idx + 1 .. i];
                if (!containsVarOrStyled(inner)) return null;
                return ConditionalGroup{
                    .inner = inner,
                    .next_index = i + 1,
                };
            }
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

const TestVar = enum { user, host, price, symbol, duration, path, missing, text, version };
test "plain text template" {
    const a = testing.allocator;
    const ctx = FormatContext(TestVar){};

    const res = try formatTemplate(a, "hello world", ctx);
    defer a.free(res);

    try testing.expectEqualStrings("hello world", res);
}

test "variable expansion outside styled groups" {
    const a = testing.allocator;
    const ctx = FormatContext(TestVar){
        .vars = &[_]Variable(TestVar){
            .{ .name = .user, .value = "luther" },
            .{ .name = .host, .value = "nixos" },
        },
    };

    const res = try formatTemplate(a, "$user@$host: ", ctx);
    defer a.free(res);

    try testing.expectEqualStrings("luther@nixos: ", res);
}

test "escaped characters" {
    const a = testing.allocator;
    const ctx = FormatContext(TestVar){
        .vars = &[_]Variable(TestVar){
            .{ .name = .price, .value = "100" },
        },
    };

    const res = try formatTemplate(a, "\\$price is \\[$price\\]", ctx);
    defer a.free(res);

    try testing.expectEqualStrings("$price is [100]", res);
}

test "styled group with explicit style" {
    const a = testing.allocator;
    const ctx = FormatContext(TestVar){
        .vars = &[_]Variable(TestVar){
            .{ .name = .symbol, .value = "➜" },
        },
    };

    const res = try formatTemplate(a, "[$symbol](bold green)", ctx);
    defer a.free(res);

    try testing.expectEqualStrings("\x1b[1;32m➜\x1b[0m", res);
}

test "styled group with $style context" {
    const a = testing.allocator;
    const ctx = FormatContext(TestVar){
        .style = "bold yellow",
        .vars = &[_]Variable(TestVar){
            .{ .name = .duration, .value = "2s" },
        },
    };

    const res = try formatTemplate(a, "took [$duration]($style) ", ctx);
    defer a.free(res);

    try testing.expectEqualStrings("took \x1b[1;33m2s\x1b[0m ", res);
}

test "advanced style strings inside format" {
    const a = testing.allocator;
    const ctx = FormatContext(TestVar){
        .vars = &[_]Variable(TestVar){
            .{ .name = .path, .value = "~/projects/zap" },
        },
    };

    const res = try formatTemplate(a, "in [$path](underline bg:#bf5700 fg:white) ", ctx);
    defer a.free(res);

    try testing.expectEqualStrings("in \x1b[4;37;48;2;191;87;0m~/projects/zap\x1b[0m ", res);
}

test "conditional group inside styled bracket" {
    const a = testing.allocator;

    // Case 1: version is empty -> ($version ) should be skipped
    const ctx1 = FormatContext(TestVar){
        .style = "bold green",
        .vars = &[_]Variable(TestVar){
            .{ .name = .symbol, .value = "➜" },
            .{ .name = .version, .value = "" },
        },
    };

    const res1 = try formatTemplate(a, "[$symbol($version )]($style)", ctx1);
    defer a.free(res1);
    try testing.expectEqualStrings("\x1b[1;32m➜\x1b[0m", res1);

    // Case 2: version is present -> ($version ) should be included
    const ctx2 = FormatContext(TestVar){
        .style = "bold green",
        .vars = &[_]Variable(TestVar){
            .{ .name = .symbol, .value = "➜ " },
            .{ .name = .version, .value = "v1.0" },
        },
    };

    const res2 = try formatTemplate(a, "[$symbol($version)]($style)", ctx2);
    defer a.free(res2);
    try testing.expectEqualStrings("\x1b[1;32m➜ v1.0\x1b[0m", res2);
}

test "empty group produces empty string" {
    const a = testing.allocator;
    const ctx = FormatContext(TestVar){
        .style = "bold red",
        .vars = &[_]Variable(TestVar){
            .{ .name = .missing, .value = "" },
        },
    };

    const res = try formatTemplate(a, "[$missing]($style)", ctx);
    defer a.free(res);
    try testing.expectEqualStrings("", res);
}

test "multiple styled groups and consecutive blocks" {
    const a = testing.allocator;
    const ctx = FormatContext(TestVar){
        .vars = &[_]Variable(TestVar){
            .{ .name = .path, .value = "~/zap" },
            .{ .name = .symbol, .value = "➜" },
        },
    };

    const res = try formatTemplate(a, "[$path](bold cyan) [$symbol](bold green) ", ctx);
    defer a.free(res);

    try testing.expectEqualStrings("\x1b[1;36m~/zap\x1b[0m \x1b[1;32m➜\x1b[0m ", res);
}

test "escaped brackets inside styled group" {
    const a = testing.allocator;
    const ctx = FormatContext(TestVar){
        .vars = &[_]Variable(TestVar){
            .{ .name = .symbol, .value = "➜" },
        },
    };

    const res = try formatTemplate(a, "[\\[$symbol\\]](bold green)", ctx);
    defer a.free(res);

    try testing.expectEqualStrings("\x1b[1;32m[➜]\x1b[0m", res);
}

test "unmatched brackets handled as literal text" {
    const a = testing.allocator;
    const ctx = FormatContext(TestVar){};

    const res = try formatTemplate(a, "normal [text without style) and (parentheses)", ctx);
    defer a.free(res);

    try testing.expectEqualStrings("normal [text without style) and (parentheses)", res);
}

test "shell zero-width escape wrapping" {
    const a = testing.allocator;
    const ctx_bash = FormatContext(TestVar){
        .shell = .bash,
        .vars = &[_]Variable(TestVar){.{ .name = .text, .value = "hi" }},
    };
    const res_bash = try formatTemplate(a, "[$text](bold green)", ctx_bash);
    defer a.free(res_bash);
    try testing.expectEqualStrings("\x01\x1b[1;32m\x02hi\x01\x1b[0m\x02", res_bash);

    const ctx_zsh = FormatContext(TestVar){
        .shell = .zsh,
        .vars = &[_]Variable(TestVar){.{ .name = .text, .value = "hi" }},
    };
    const res_zsh = try formatTemplate(a, "[$text](bold green)", ctx_zsh);
    defer a.free(res_zsh);
    try testing.expectEqualStrings("%{\x1b[1;32m%}hi%{\x1b[0m%}", res_zsh);

    const ctx_fish = FormatContext(TestVar){
        .shell = .fish,
        .vars = &[_]Variable(TestVar){.{ .name = .text, .value = "hi" }},
    };
    const res_fish = try formatTemplate(a, "[$text](bold green)", ctx_fish);
    defer a.free(res_fish);
    try testing.expectEqualStrings("\x1b[1;32mhi\x1b[0m", res_fish);
}

