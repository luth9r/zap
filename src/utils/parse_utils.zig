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
