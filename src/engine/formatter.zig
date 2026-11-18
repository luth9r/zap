const std = @import("std");
const testing = std.testing;
const style_mod = @import("style.zig");
const parse_utils = @import("../utils/parse_utils.zig");
const BufferWriter = @import("../utils/buffer_writer.zig").BufferWriter;
const extractVarName = parse_utils.extractVarName;

pub fn Variable(comptime EnumType: type) type {
    return struct {
        name: EnumType,
        value: []const u8,
        /// When true, dynamic untrusted text (e.g. directory paths, git branch/tag names)
        /// is escaped for target shell prompt expansion (Bash `$`/`\``, Zsh `%`/`$`/`\``).
        escape_shell: bool = false,
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

        pub fn shouldEscapeShell(self: @This(), name_str: []const u8) bool {
            if (std.mem.eql(u8, name_str, "style")) return false;
            const name = std.meta.stringToEnum(EnumType, name_str) orelse return false;
            for (self.vars) |v| {
                if (v.name == name) {
                    return v.escape_shell;
                }
            }
            return false;
        }
    };
}

/// Writes dynamic user text (paths, branch names, tags) escaping characters that trigger
/// shell prompt command substitution or prompt escape sequences.
pub fn writeShellSafeValue(writer: anytype, val: []const u8, shell: Shell) !void {
    switch (shell) {
        .bash => {
            for (val, 0..) |c, idx| {
                if (c == '$' or c == '`') {
                    try writer.writeByte('\\');
                    try writer.writeByte(c);
                } else if (c == '\\' and idx + 1 < val.len and (val[idx + 1] == '$' or val[idx + 1] == '`' or val[idx + 1] == '\\')) {
                    try writer.writeAll("\\\\");
                } else {
                    try writer.writeByte(c);
                }
            }
        },
        .zsh => {
            for (val) |c| {
                if (c == '%') {
                    try writer.writeAll("%%");
                } else if (c == '$' or c == '`') {
                    try writer.writeByte('\\');
                    try writer.writeByte(c);
                } else {
                    try writer.writeByte(c);
                }
            }
        },
        .fish, .powershell, .cmd, .generic => {
            try writer.writeAll(val);
        },
    }
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
fn writeEscapedByte(writer: anytype, esc: u8) !void {
    switch (esc) {
        'n' => try writer.writeByte('\n'),
        't' => try writer.writeByte('\t'),
        'r' => try writer.writeByte('\r'),
        else => try writer.writeByte(esc),
    }
}

fn renderTemplate(
    writer: anytype,
    template: []const u8,
    ctx: anytype,
    comptime allow_styled_groups: bool,
) !void {
    var i: usize = 0;
    while (i < template.len) {
        if (template[i] == '\\' and i + 1 < template.len) {
            try writeEscapedByte(writer, template[i + 1]);
            i += 2;
            continue;
        }
        if (template[i] == '(') {
            if (parseConditionalGroup(template, i)) |cond| {
                if (shouldRenderConditionalGroup(cond.inner, ctx)) {
                    try renderTemplate(writer, cond.inner, ctx, allow_styled_groups);
                }
                i = cond.next_index;
                continue;
            }
        }
        if (allow_styled_groups and template[i] == '[') {
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
                    if (comptime @hasDecl(@TypeOf(ctx), "shouldEscapeShell")) {
                        if (ctx.shouldEscapeShell(var_name)) {
                            try writeShellSafeValue(writer, val, ctx.shell);
                        } else {
                            try writer.writeAll(val);
                        }
                    } else {
                        try writer.writeAll(val);
                    }
                }
                i += 1 + var_name.len;
                continue;
            }
        }
        try writer.writeByte(template[i]);
        i += 1;
    }
}

pub fn formatTemplateWriter(
    writer: anytype,
    template: []const u8,
    ctx: anytype,
) !void {
    try renderTemplate(writer, template, ctx, true);
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
    const close_bracket = parse_utils.findMatchingDelimiter(template, start_idx, '[', ']') orelse return null;
    if (close_bracket + 1 >= template.len or template[close_bracket + 1] != '(') {
        return null;
    }
    const close_paren = parse_utils.findMatchingDelimiter(template, close_bracket + 1, '(', ')') orelse return null;

    return StyledGroup{
        .content = template[start_idx + 1 .. close_bracket],
        .style_spec = template[close_bracket + 2 .. close_paren],
        .next_index = close_paren + 1,
    };
}

fn zeroWidthWrapperOverhead(shell: Shell) usize {
    return switch (shell) {
        .bash => 2,
        .zsh => 4,
        .fish, .powershell, .cmd, .generic => 0,
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

    const reset_seq = "\x1b[0m";
    const wrapper_ovh = zeroWidthWrapperOverhead(ctx.shell);
    const open_needed = if (style_ansi.len > 0) style_ansi.len + wrapper_ovh else 0;
    const close_needed = if (style_ansi.len > 0) reset_seq.len + wrapper_ovh else 0;

    if (comptime @TypeOf(writer) == BufferWriter) {
        if (style_ansi.len > 0 and writer.remaining() < open_needed + close_needed) {
            // Not enough space for both opening and closing ANSI tags; write plain content
            try renderGroupContent(writer, content_raw, ctx);
            return;
        }
        if (style_ansi.len > 0) {
            try writeZeroWidthAnsi(writer, style_ansi, ctx.shell);
            const reserved_writer = BufferWriter.init(writer.buf[0 .. writer.buf.len - close_needed], writer.pos);
            try renderGroupContent(reserved_writer, content_raw, ctx);
            try writeZeroWidthAnsi(writer, reset_seq, ctx.shell);
            return;
        }
    }

    if (style_ansi.len > 0)
        try writeZeroWidthAnsi(writer, style_ansi, ctx.shell);

    try renderGroupContent(writer, content_raw, ctx);

    if (style_ansi.len > 0)
        try writeZeroWidthAnsi(writer, reset_seq, ctx.shell);
}

pub fn writeZeroWidthAnsi(writer: anytype, ansi_seq: []const u8, shell: Shell) !void {
    if (comptime @TypeOf(writer) == BufferWriter) {
        const needed = ansi_seq.len + zeroWidthWrapperOverhead(shell);
        if (writer.remaining() < needed) return;
    }
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
        .fish, .powershell, .cmd, .generic => {
            try writer.writeAll(ansi_seq);
        },
    }
}

const GroupInspection = struct {
    has_var: bool = false,
    has_non_empty_var: bool = false,
    has_literal: bool = false,
};

fn inspectGroupVars(raw: []const u8, ctx: anytype) GroupInspection {
    var res = GroupInspection{};
    var i: usize = 0;

    while (i < raw.len) {
        if (raw[i] == '\\' and i + 1 < raw.len) {
            res.has_literal = true;
            i += 2;
            continue;
        }
        if (raw[i] == '(') {
            if (parseConditionalGroup(raw, i)) |cond| {
                const sub = inspectGroupVars(cond.inner, ctx);
                if (!sub.has_var or sub.has_non_empty_var) {
                    res.has_non_empty_var = true;
                } else {
                    res.has_var = true;
                }
                i = cond.next_index;
                continue;
            }
        }
        if (raw[i] == '[') {
            if (parseStyledGroup(raw, i)) |group| {
                res.has_var = true;
                if (!isGroupContentEmpty(group.content, ctx)) {
                    res.has_non_empty_var = true;
                }
                i = group.next_index;
                continue;
            }
        }
        if (raw[i] == '$') {
            const var_name = extractVarName(raw[i + 1 ..]);
            if (var_name.len > 0) {
                res.has_var = true;
                if (ctx.get(var_name)) |val| {
                    if (val.len > 0) res.has_non_empty_var = true;
                }
                i += 1 + var_name.len;
                continue;
            }
        }
        res.has_literal = true;
        i += 1;
    }

    return res;
}

fn isGroupContentEmpty(raw: []const u8, ctx: anytype) bool {
    const info = inspectGroupVars(raw, ctx);
    if (info.has_var) {
        return !info.has_non_empty_var;
    }
    return !info.has_literal;
}

fn renderGroupContent(
    writer: anytype,
    raw: []const u8,
    ctx: anytype,
) !void {
    try renderTemplate(writer, raw, ctx, false);
}

fn shouldRenderConditionalGroup(inner: []const u8, ctx: anytype) bool {
    const info = inspectGroupVars(inner, ctx);
    return !info.has_var or info.has_non_empty_var;
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
    const close_paren = parse_utils.findMatchingDelimiter(raw, start_idx, '(', ')') orelse return null;
    const inner = raw[start_idx + 1 .. close_paren];
    if (!containsVarOrStyled(inner)) return null;
    return ConditionalGroup{
        .inner = inner,
        .next_index = close_paren + 1,
    };
}

const TestVar = enum { user, host, price, symbol, duration, path, missing, text, version };
test "unit: plain text template" {
    const a = testing.allocator;
    const ctx = FormatContext(TestVar){};

    const res = try formatTemplate(a, "hello world", ctx);
    defer a.free(res);

    try testing.expectEqualStrings("hello world", res);
}

test "unit: variable expansion outside styled groups" {
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

test "unit: escaped characters" {
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

test "unit: styled group with explicit style" {
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

test "unit: styled group with $style context" {
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

test "unit: advanced style strings inside format" {
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

test "unit: conditional group inside styled bracket" {
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

test "unit: empty group produces empty string" {
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

test "unit: multiple styled groups and consecutive blocks" {
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

test "unit: escaped brackets inside styled group" {
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

test "unit: unmatched brackets handled as literal text" {
    const a = testing.allocator;
    const ctx = FormatContext(TestVar){};

    const res = try formatTemplate(a, "normal [text without style) and (parentheses)", ctx);
    defer a.free(res);

    try testing.expectEqualStrings("normal [text without style) and (parentheses)", res);
}

test "unit: shell zero-width escape wrapping" {
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

test "unit: multi-byte UTF-8 and emojis in styled template" {
    const a = testing.allocator;
    const ctx = FormatContext(TestVar){
        .shell = .generic,
        .vars = &[_]Variable(TestVar){
            .{ .name = .symbol, .value = "🦀 " },
            .{ .name = .text, .value = "master ⚡" },
        },
    };

    const res = try formatTemplate(a, "[$symbol$text](bold red) ", ctx);
    defer a.free(res);
    try testing.expectEqualStrings("\x1b[1;31m🦀 master ⚡\x1b[0m ", res);
}

test "unit: conditional group wrapping styled block with $style skips when content vars are empty" {
    const a = testing.allocator;
    const ctx_empty = FormatContext(TestVar){
        .style = "bold red",
        .vars = &[_]Variable(TestVar){
            .{ .name = .missing, .value = "" },
        },
    };

    const res_empty = try formatTemplate(a, "([\\[$missing\\]]($style) )", ctx_empty);
    defer a.free(res_empty);
    try testing.expectEqualStrings("", res_empty);

    const ctx_non_empty = FormatContext(TestVar){
        .style = "bold red",
        .vars = &[_]Variable(TestVar){
            .{ .name = .text, .value = "!+" },
        },
    };

    const res_non_empty = try formatTemplate(a, "([\\[$text\\]]($style) )", ctx_non_empty);
    defer a.free(res_non_empty);
    try testing.expectEqualStrings("\x1b[1;31m[!+]\x1b[0m ", res_non_empty);
}

test "unit: escape_shell prevents command injection in bash and prompt expansion in zsh" {
    const a = testing.allocator;

    const ctx_bash = FormatContext(TestVar){
        .shell = .bash,
        .vars = &[_]Variable(TestVar){
            .{ .name = .path, .value = "~/dir$(id)`uname`", .escape_shell = true },
        },
    };
    const res_bash = try formatTemplate(a, "[$path](cyan)", ctx_bash);
    defer a.free(res_bash);
    try testing.expectEqualStrings("\x01\x1b[36m\x02~/dir\\$(id)\\`uname\\`\x01\x1b[0m\x02", res_bash);

    const ctx_zsh = FormatContext(TestVar){
        .shell = .zsh,
        .vars = &[_]Variable(TestVar){
            .{ .name = .path, .value = "~/100%F{red}$(id)", .escape_shell = true },
        },
    };
    const res_zsh = try formatTemplate(a, "[$path](cyan)", ctx_zsh);
    defer a.free(res_zsh);
    try testing.expectEqualStrings("%{\x1b[36m%}~/100%%F{red}\\$(id)%{\x1b[0m%}", res_zsh);
}

test "unit: truncated BufferWriter preserves balanced ANSI reset and shell zero-width markers" {
    const Fixture = @import("../tests/fixture.zig").Fixture;
    var small_buf: [24]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&small_buf, &pos);

    const ctx = FormatContext(TestVar){
        .shell = .bash,
        .vars = &[_]Variable(TestVar){
            .{ .name = .path, .value = "very_long_directory_name_exceeding_buffer" },
        },
    };
    try formatTemplateWriter(writer, "[$path](bold cyan)", ctx);
    try Fixture.assertValidShellAnsi(small_buf[0..pos], .bash);
    try testing.expect(std.mem.endsWith(u8, small_buf[0..pos], "\x01\x1b[0m\x02"));
}
