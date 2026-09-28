const std = @import("std");

/// Matches a simple gitignore pattern against a file or directory name.
pub fn isGitignorePatternMatch(pattern_raw: []const u8, name: []const u8) bool {
    const pattern = std.mem.trim(u8, pattern_raw, " \t\r\n");
    if (pattern.len == 0 or pattern[0] == '#') return false;

    var pat = pattern;
    if (std.mem.startsWith(u8, pat, "/")) pat = pat[1..];
    if (std.mem.endsWith(u8, pat, "/")) pat = pat[0 .. pat.len - 1];
    if (pat.len == 0) return false;

    if (std.mem.startsWith(u8, pat, "*")) {
        const suffix = pat[1..];
        return std.mem.endsWith(u8, name, suffix);
    } else if (std.mem.endsWith(u8, pat, "*")) {
        const prefix = pat[0 .. pat.len - 1];
        return std.mem.startsWith(u8, name, prefix);
    } else if (std.mem.indexOfScalar(u8, pat, '*')) |star_idx| {
        const prefix = pat[0..star_idx];
        const suffix = pat[star_idx + 1 ..];
        return std.mem.startsWith(u8, name, prefix) and std.mem.endsWith(u8, name, suffix) and (name.len >= prefix.len + suffix.len);
    } else {
        return std.mem.eql(u8, name, pat);
    }
}

/// Checks if a file or directory name matches any pattern in an ignore file (.gitignore or info/exclude).
pub fn isNameInIgnoreFile(io: std.Io, ignore_file_path: []const u8, name: []const u8) bool {
    const file = std.Io.Dir.openFileAbsolute(io, ignore_file_path, .{}) catch return false;
    defer file.close(io);

    var stream_buf: [1024]u8 = undefined;
    var r = file.reader(io, &stream_buf);
    var line_buf: [256]u8 = undefined;
    var line_pos: usize = 0;

    while (true) {
        var c_buf: [1]u8 = undefined;
        const cr = r.interface.readSliceShort(&c_buf) catch 0;
        if (cr == 0) {
            if (line_pos > 0) {
                if (isGitignorePatternMatch(line_buf[0..line_pos], name)) return true;
            }
            break;
        }
        if (c_buf[0] == '\n') {
            if (line_pos > 0) {
                if (isGitignorePatternMatch(line_buf[0..line_pos], name)) return true;
            }
            line_pos = 0;
        } else if (line_pos < line_buf.len) {
            line_buf[line_pos] = c_buf[0];
            line_pos += 1;
        }
    }
    return false;
}

/// Checks whether a name is ignored according to .gitignore or .git/info/exclude.
pub fn isIgnored(io: std.Io, work_dir: []const u8, git_dir: []const u8, name: []const u8) bool {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;

    // 1. Check <work_dir>/.gitignore
    if (std.fmt.bufPrint(&path_buf, "{s}/.gitignore", .{work_dir})) |gitignore_path| {
        if (isNameInIgnoreFile(io, gitignore_path, name)) return true;
    } else |_| {}

    // 2. Check <git_dir>/info/exclude
    if (std.fmt.bufPrint(&path_buf, "{s}/info/exclude", .{git_dir})) |exclude_path| {
        if (isNameInIgnoreFile(io, exclude_path, name)) return true;
    } else |_| {}

    return false;
}

test "isGitignorePatternMatch patterns" {
    try std.testing.expect(isGitignorePatternMatch("*.tar.gz", "zap-v0.1.0-x86_64-linux.tar.gz"));
    try std.testing.expect(isGitignorePatternMatch("*.zip", "zap-v0.1.0-x86_64-windows.zip"));
    try std.testing.expect(isGitignorePatternMatch("*.o", "main.o"));
    try std.testing.expect(!isGitignorePatternMatch("*.o", "main.zig"));

    try std.testing.expect(isGitignorePatternMatch("zig-out/", "zig-out"));
    try std.testing.expect(isGitignorePatternMatch(".idea/", ".idea"));

    try std.testing.expect(isGitignorePatternMatch("temp*", "temp_file.txt"));
    try std.testing.expect(!isGitignorePatternMatch("temp*", "other.txt"));

    try std.testing.expect(isGitignorePatternMatch("LICENSE", "LICENSE"));
    try std.testing.expect(!isGitignorePatternMatch("LICENSE", "README.md"));
}
