const std = @import("std");
const testing = std.testing;
const BufferWriter = @import("buffer_writer.zig").BufferWriter;

pub fn writePath(
    writer: anytype,
    cwd: []const u8,
    home: []const u8,
    home_symbol: []const u8,
) !void {
    if (home.len > 0 and std.mem.startsWith(u8, cwd, home)) {
        if (cwd.len == home.len) {
            try writer.writeAll(home_symbol);
            return;
        }
        if (cwd[home.len] == '/') {
            try writer.writeAll(home_symbol);
            try writer.writeAll(cwd[home.len..]);
            return;
        }
    }
    try writer.writeAll(cwd);
}

pub fn formatPathBuf(
    buf: []u8,
    cwd: []const u8,
    home: []const u8,
    home_symbol: []const u8,
) ?[]const u8 {
    var pos: usize = 0;
    const writer = BufferWriter.init(buf, &pos);
    writePath(writer, cwd, home, home_symbol) catch return null;
    return buf[0..pos];
}

pub fn formatPathTruncatedBuf(
    buf: []u8,
    cwd: []const u8,
    home: []const u8,
    home_symbol: []const u8,
    truncation_length: usize,
    truncation_symbol: []const u8,
    repo_root: ?[]const u8,
) ?[]const u8 {
    // 1. Truncate to repo root if provided and cwd is inside repository
    if (repo_root) |root| {
        if (std.mem.startsWith(u8, cwd, root)) {
            const repo_name = std.fs.path.basename(root);
            if (cwd.len == root.len) {
                return std.fmt.bufPrint(buf, "{s}", .{repo_name}) catch null;
            } else if (cwd[root.len] == '/' or cwd[root.len] == '\\') {
                const rel_path = cwd[root.len + 1 ..];
                if (truncation_length == 0) {
                    return std.fmt.bufPrint(buf, "{s}/{s}", .{ repo_name, rel_path }) catch null;
                }

                var segments_count: usize = 1; // starts with repo_name
                var it = std.mem.tokenizeAny(u8, rel_path, "/\\");
                while (it.next()) |_| {
                    segments_count += 1;
                }

                if (segments_count <= truncation_length) {
                    return std.fmt.bufPrint(buf, "{s}/{s}", .{ repo_name, rel_path }) catch null;
                }

                const skip_segments = segments_count - truncation_length;
                if (skip_segments == 1) {
                    return std.fmt.bufPrint(buf, "{s}{s}", .{ truncation_symbol, rel_path }) catch null;
                } else {
                    var skip_idx: usize = 0;
                    var passed: usize = 1;
                    var seg_it = std.mem.tokenizeAny(u8, rel_path, "/\\");
                    while (seg_it.next()) |seg| {
                        passed += 1;
                        if (passed > skip_segments) {
                            skip_idx = @intFromPtr(seg.ptr) - @intFromPtr(rel_path.ptr);
                            break;
                        }
                    }
                    return std.fmt.bufPrint(buf, "{s}{s}", .{ truncation_symbol, rel_path[skip_idx..] }) catch null;
                }
            }
        }
    }

    // 2. Format with home replacement
    var full_buf: [std.fs.max_path_bytes]u8 = undefined;
    const full_path = formatPathBuf(&full_buf, cwd, home, home_symbol) orelse cwd;

    if (truncation_length == 0) {
        return std.fmt.bufPrint(buf, "{s}", .{full_path}) catch null;
    }

    const is_home_prefixed = (home_symbol.len > 0 and std.mem.startsWith(u8, full_path, home_symbol));
    const is_exact_home = is_home_prefixed and (full_path.len == home_symbol.len);

    if (is_exact_home) {
        return std.fmt.bufPrint(buf, "{s}", .{home_symbol}) catch null;
    }

    const path_after_home = if (is_home_prefixed and full_path.len > home_symbol.len and (full_path[home_symbol.len] == '/' or full_path[home_symbol.len] == '\\'))
        full_path[home_symbol.len + 1 ..]
    else
        std.mem.trimStart(u8, full_path, "/\\");

    var total_segments: usize = if (is_home_prefixed) 1 else 0;
    var count_it = std.mem.tokenizeAny(u8, path_after_home, "/\\");
    while (count_it.next()) |_| {
        total_segments += 1;
    }

    if (total_segments <= truncation_length) {
        return std.fmt.bufPrint(buf, "{s}", .{full_path}) catch null;
    }

    const segments_to_skip = total_segments - truncation_length;
    var seg_start: usize = 0;
    var skipped: usize = if (is_home_prefixed) 1 else 0;

    var iter = std.mem.tokenizeAny(u8, path_after_home, "/\\");
    while (iter.next()) |seg| {
        if (skipped >= segments_to_skip) {
            seg_start = @intFromPtr(seg.ptr) - @intFromPtr(path_after_home.ptr);
            break;
        }
        skipped += 1;
    }

    const remaining = path_after_home[seg_start..];

    if (is_home_prefixed and segments_to_skip > 0) {
        return std.fmt.bufPrint(buf, "{s}/{s}{s}", .{ home_symbol, truncation_symbol, remaining }) catch null;
    } else {
        return std.fmt.bufPrint(buf, "{s}{s}", .{ truncation_symbol, remaining }) catch null;
    }
}

test "replaces HOME prefix with default tilde" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = "/home/user";
    const cwd = "/home/user/projects/zap";

    const result = formatPathBuf(&buf, cwd, home, "~").?;
    try testing.expectEqualStrings("~/projects/zap", result);
}

test "replaces HOME prefix with custom configured symbol" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = "/home/user";
    const cwd = "/home/user/projects/zap";

    const result = formatPathBuf(&buf, cwd, home, "?>").?;
    try testing.expectEqualStrings("?>/projects/zap", result);
}

test "handles exact HOME match with custom symbol" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = "/home/user";
    const cwd = "/home/user";

    const result = formatPathBuf(&buf, cwd, home, "?>").?;
    try testing.expectEqualStrings("?>", result);
}

test "formatPathTruncatedBuf with truncation length" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = "/home/user";
    const cwd = "/home/user/projects/zap/src/modules";

    // Truncate to 3 segments: ~/…/zap/src/modules
    const res3 = formatPathTruncatedBuf(&buf, cwd, home, "~", 3, "…/", null).?;
    try testing.expectEqualStrings("~/…/zap/src/modules", res3);

    // Truncate to 1 segment: ~/…/modules
    const res1 = formatPathTruncatedBuf(&buf, cwd, home, "~", 1, "…/", null).?;
    try testing.expectEqualStrings("~/…/modules", res1);

    // No truncation when length >= total segments
    const res5 = formatPathTruncatedBuf(&buf, cwd, home, "~", 5, "…/", null).?;
    try testing.expectEqualStrings("~/projects/zap/src/modules", res5);
}

test "formatPathTruncatedBuf with repo root" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = "/home/user";
    const repo_root = "/home/user/projects/zap";
    const cwd = "/home/user/projects/zap/src/engine";

    const res = formatPathTruncatedBuf(&buf, cwd, home, "~", 3, "…/", repo_root).?;
    try testing.expectEqualStrings("zap/src/engine", res);
}
