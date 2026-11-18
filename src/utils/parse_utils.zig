const std = @import("std");

/// Extracts an identifier / variable name starting at the beginning of `slice`.
/// Stops at the first non-alphanumeric and non-underscore character.
pub fn extractVarName(slice: []const u8) []const u8 {
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

/// Finds the index of the matching closing delimiter (`close_char`) for the opening delimiter
/// at `str[start_idx]`, accounting for nested delimiter pairs and backslash escapes.
pub fn findMatchingDelimiter(
    str: []const u8,
    start_idx: usize,
    open_char: u8,
    close_char: u8,
) ?usize {
    if (start_idx >= str.len or str[start_idx] != open_char) return null;
    var depth: usize = 0;
    var i: usize = start_idx;
    while (i < str.len) {
        if (str[i] == '\\' and i + 1 < str.len) {
            i += 2;
            continue;
        }
        if (str[i] == open_char) {
            depth += 1;
        } else if (str[i] == close_char) {
            depth -= 1;
            if (depth == 0) return i;
        }
        i += 1;
    }
    return null;
}

/// If `str[i..]` begins with a Bash zero-width marker (`\x01`/`\x02`), Zsh marker (`%{`/`%}`),
/// or CSI ANSI escape sequence (`\x1b[...m`), returns the index immediately following it.
pub fn skipAnsiOrShellMarker(str: []const u8, i: usize) ?usize {
    if (i >= str.len) return null;
    if (str[i] == '\x01' or str[i] == '\x02') {
        return i + 1;
    }
    if (i + 1 < str.len and str[i] == '%' and (str[i + 1] == '{' or str[i + 1] == '}')) {
        return i + 2;
    }
    if (str[i] == '\x1b' and i + 1 < str.len and str[i + 1] == '[') {
        var j = i + 2;
        while (j < str.len and str[j] != 'm') : (j += 1) {}
        if (j < str.len) j += 1;
        return j;
    }
    return null;
}

fn jsonEscapeSeq(c: u8) ?[]const u8 {
    return switch (c) {
        '\\' => "\\\\",
        '"' => "\\\"",
        '\n' => "\\n",
        '\r' => "\\r",
        '\t' => "\\t",
        else => null,
    };
}

/// Escapes a string for safe inclusion inside a JSON string literal into `buf`.
pub fn escapeJsonBuf(buf: []u8, input: []const u8) []const u8 {
    var pos: usize = 0;
    for (input) |c| {
        if (jsonEscapeSeq(c)) |s| {
            if (pos + s.len > buf.len) break;
            @memcpy(buf[pos .. pos + s.len], s);
            pos += s.len;
        } else {
            if (pos + 1 > buf.len) break;
            buf[pos] = c;
            pos += 1;
        }
    }
    return buf[0..pos];
}

/// Writes a JSON-escaped string directly to `writer` without heap allocations.
pub fn writeJsonEscaped(writer: anytype, input: []const u8) !void {
    for (input) |c| {
        if (jsonEscapeSeq(c)) |s| {
            try writer.writeAll(s);
        } else {
            try writer.writeByte(c);
        }
    }
}

test "unit: escapeJsonBuf escapes quotes, backslashes, and control chars" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("a\\\"b\\\\c\\n", escapeJsonBuf(&buf, "a\"b\\c\n"));
}

test "unit: writeJsonEscaped matches escapeJsonBuf and avoids partial escapes on truncation" {
    const BufferWriter = @import("buffer_writer.zig").BufferWriter;
    var w_buf: [64]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&w_buf, &pos);
    try writeJsonEscaped(writer, "a\"b\\c\n\r\t");

    var b_buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings(escapeJsonBuf(&b_buf, "a\"b\\c\n\r\t"), writer.written());

    // 2-byte buffer cannot fit escaped "\n" after "a" (needs 3 bytes), so it stops cleanly at "a"
    var small_buf: [2]u8 = undefined;
    try std.testing.expectEqualStrings("a", escapeJsonBuf(&small_buf, "a\n"));
}

test "unit: extractVarName extracts valid identifier tokens" {
    const testing = std.testing;

    try testing.expectEqualStrings("foo", extractVarName("foo"));
    try testing.expectEqualStrings("foo_bar", extractVarName("foo_bar"));
    try testing.expectEqualStrings("zig_lang", extractVarName("zig_lang/bar"));
    try testing.expectEqualStrings("directory", extractVarName("directory$character"));
    try testing.expectEqualStrings("user123", extractVarName("user123:hello"));
    try testing.expectEqualStrings("", extractVarName("!invalid"));
    try testing.expectEqualStrings("", extractVarName(""));
}

test "unit: findMatchingDelimiter handles nesting and escapes" {
    const testing = std.testing;
    try testing.expectEqual(@as(?usize, 5), findMatchingDelimiter("[a[b]]", 0, '[', ']'));
    try testing.expectEqual(@as(?usize, 4), findMatchingDelimiter("[\\]a]", 0, '[', ']'));
    try testing.expectEqual(@as(?usize, null), findMatchingDelimiter("[unclosed", 0, '[', ']'));
}
