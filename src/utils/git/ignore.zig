const std = @import("std");
const testing = std.testing;

pub const GitIgnore = struct {
    content: []const u8 = "",

    pub fn init(content: []const u8) GitIgnore {
        return .{ .content = content };
    }

    pub fn parse(content: []const u8) GitIgnore {
        return .{ .content = content };
    }

    pub fn isIgnored(self: GitIgnore, rel_path: []const u8, is_dir: bool) bool {
        if (rel_path.len == 0 or self.content.len == 0) return false;

        // Strip leading '/' or './'
        var path = rel_path;
        if (std.mem.startsWith(u8, path, "./")) {
            path = path[2..];
        } else if (path[0] == '/') {
            path = path[1..];
        }

        const base_name = std.fs.path.basename(path);
        var ignored = false;

        var line_it = std.mem.splitScalar(u8, self.content, '\n');
        while (line_it.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;

            var pattern = line;
            var is_negation = false;
            if (pattern[0] == '!') {
                is_negation = true;
                pattern = pattern[1..];
            }

            var is_dir_only = false;
            if (pattern.len > 0 and pattern[pattern.len - 1] == '/') {
                is_dir_only = true;
                pattern = pattern[0 .. pattern.len - 1];
            }

            // Check if pattern is anchored to repo root (starts with / or has / inside)
            const is_anchored = (std.mem.indexOfScalar(u8, pattern, '/') != null);

            // Strip leading '/' if present
            if (pattern.len > 0 and pattern[0] == '/') {
                pattern = pattern[1..];
            }

            if (is_dir_only and !is_dir) {
                // If rule is directory-only, check if any parent directory segment matches
                var it = std.mem.splitScalar(u8, path, '/');
                var matched_parent = false;
                while (it.next()) |segment| {
                    if (matchPattern(pattern, segment)) {
                        matched_parent = true;
                        break;
                    }
                }
                if (matched_parent) {
                    ignored = !is_negation;
                }
                continue;
            }

            // If pattern contains '/', it must match the relative path. Otherwise, it matches anywhere (basename).
            if (matchPattern(pattern, path) or (!is_anchored and matchPattern(pattern, base_name))) {
                ignored = !is_negation;
            }
        }

        return ignored;
    }

    /// Performs fnmatch/glob matching with support for *, ?, and character sets [a-z], [0-9], [!abc].
    pub fn globMatch(pattern: []const u8, str: []const u8) bool {
        var p_idx: usize = 0;
        var s_idx: usize = 0;
        var star_p: ?usize = null;
        var star_s: usize = 0;

        while (s_idx < str.len) {
            if (p_idx < pattern.len and pattern[p_idx] == '[') {
                if (std.mem.indexOfScalar(u8, pattern[p_idx..], ']')) |close_offset| {
                    const close_idx = p_idx + close_offset;
                    const class_content = pattern[p_idx + 1 .. close_idx];
                    var negated = false;
                    var class_chars = class_content;
                    if (class_chars.len > 0 and (class_chars[0] == '!' or class_chars[0] == '^')) {
                        negated = true;
                        class_chars = class_chars[1..];
                    }

                    var matched = false;
                    var c_i: usize = 0;
                    while (c_i < class_chars.len) {
                        if (c_i + 2 < class_chars.len and class_chars[c_i + 1] == '-') {
                            const start = class_chars[c_i];
                            const end = class_chars[c_i + 2];
                            if (str[s_idx] >= start and str[s_idx] <= end) {
                                matched = true;
                                break;
                            }
                            c_i += 3;
                        } else {
                            if (str[s_idx] == class_chars[c_i]) {
                                matched = true;
                                break;
                            }
                            c_i += 1;
                        }
                    }

                    if (negated) matched = !matched;

                    if (matched) {
                        p_idx = close_idx + 1;
                        s_idx += 1;
                        continue;
                    }
                }
            }

            if (p_idx < pattern.len and (pattern[p_idx] == '?' or pattern[p_idx] == str[s_idx])) {
                p_idx += 1;
                s_idx += 1;
            } else if (p_idx < pattern.len and pattern[p_idx] == '*') {
                star_p = p_idx;
                p_idx += 1;
                star_s = s_idx;
            } else if (star_p) |sp| {
                p_idx = sp + 1;
                star_s += 1;
                s_idx = star_s;
            } else {
                return false;
            }
        }

        while (p_idx < pattern.len and pattern[p_idx] == '*') {
            p_idx += 1;
        }

        return p_idx == pattern.len;
    }

    pub fn matchPattern(pattern: []const u8, target: []const u8) bool {
        if (pattern.len == 0 or target.len == 0) return false;

        // Exact match
        if (std.mem.eql(u8, pattern, target)) return true;

        // Pattern starting with **/ (e.g. **/dist or **/*.log)
        if (std.mem.startsWith(u8, pattern, "**/")) {
            const sub = pattern[3..];
            if (sub.len == 0) return true;
            if (matchPattern(sub, target) or matchPattern(sub, std.fs.path.basename(target))) return true;
            var it = std.mem.splitScalar(u8, target, '/');
            while (it.next()) |seg| {
                if (matchPattern(sub, seg)) return true;
            }
            if (std.mem.endsWith(u8, target, sub)) {
                const idx = target.len - sub.len;
                if (idx == 0 or target[idx - 1] == '/') return true;
            }
            return false;
        }

        // Pattern ending with /** (e.g. dist/**)
        if (std.mem.endsWith(u8, pattern, "/**")) {
            const prefix = pattern[0 .. pattern.len - 3];
            if (std.mem.eql(u8, target, prefix)) return true;
            if (std.mem.startsWith(u8, target, prefix)) {
                if (target.len > prefix.len and target[prefix.len] == '/') return true;
            }
            return false;
        }

        // Pattern with middle /**/ (e.g. a/**/b)
        if (std.mem.indexOf(u8, pattern, "/**/")) |star_idx| {
            const prefix = pattern[0..star_idx];
            const suffix = pattern[star_idx + 4 ..];
            const prefix_matches = (prefix.len == 0) or (std.mem.startsWith(u8, target, prefix) and (target.len == prefix.len or target[prefix.len] == '/'));
            const suffix_matches = (suffix.len == 0) or (std.mem.endsWith(u8, target, suffix) and (target.len == suffix.len or target[target.len - suffix.len - 1] == '/'));
            if (prefix_matches and suffix_matches and target.len >= prefix.len + suffix.len) return true;
        }

        return globMatch(pattern, target);
    }
};

test "unit: GitIgnore parses comments and empty lines" {
    const content =
        \\# This is a comment
        \\
        \\   # Indented comment
        \\*.log
        \\node_modules/
    ;
    const gi = GitIgnore.parse(content);
    try testing.expect(gi.isIgnored("app.log", false));
    try testing.expect(gi.isIgnored("node_modules", true));
}

test "unit: GitIgnore matches extension pattern *.ext" {
    const gi = GitIgnore.parse("*.log\n*.tmp");
    try testing.expect(gi.isIgnored("app.log", false));
    try testing.expect(gi.isIgnored("nested/dir/server.log", false));
    try testing.expect(gi.isIgnored("data.tmp", false));
    try testing.expect(!gi.isIgnored("app.zig", false));
    try testing.expect(!gi.isIgnored("log.txt", false));
}

test "unit: GitIgnore matches directory-only rules" {
    const gi = GitIgnore.parse("zig-cache/\ntarget/\n");
    try testing.expect(gi.isIgnored("zig-cache", true));
    try testing.expect(gi.isIgnored("target", true));
    try testing.expect(gi.isIgnored("zig-cache/o/file.bin", false));
    try testing.expect(gi.isIgnored("target/debug/app", false));
    try testing.expect(!gi.isIgnored("zig-cache.txt", false));
}

test "unit: GitIgnore matches exact filenames" {
    const gi = GitIgnore.parse(".DS_Store\nconfig.toml\n");
    try testing.expect(gi.isIgnored(".DS_Store", false));
    try testing.expect(gi.isIgnored("nested/config.toml", false));
    try testing.expect(!gi.isIgnored("config.toml.bak", false));
}

test "unit: GitIgnore handles negation rule" {
    const gi = GitIgnore.parse("*.log\n!important.log\n");
    try testing.expect(gi.isIgnored("error.log", false));
    try testing.expect(!gi.isIgnored("important.log", false));
}

test "unit: GitIgnore double star glob matching" {
    const gi = GitIgnore.parse("**/dist\nbuild/**\nsrc/**/test\n*cache*\n");
    try testing.expect(gi.isIgnored("dist", false));
    try testing.expect(gi.isIgnored("nested/dist", false));
    try testing.expect(gi.isIgnored("a/b/c/dist", false));
    try testing.expect(gi.isIgnored("build/out.bin", false));
    try testing.expect(gi.isIgnored("src/utils/test", false));
    try testing.expect(gi.isIgnored("app.cache.tmp", false));
    try testing.expect(!gi.isIgnored("src/utils/other.zig", false));
}

test "unit: GitIgnore root anchored paths and leading slash" {
    const gi = GitIgnore.parse("/root_only.txt\ndoc/frotz\n");
    // /root_only.txt should match in root, but NOT inside subdirectories
    try testing.expect(gi.isIgnored("root_only.txt", false));
    try testing.expect(!gi.isIgnored("subdir/root_only.txt", false));

    // doc/frotz has a slash in the middle, so it matches doc/frotz but not other/doc/frotz
    try testing.expect(gi.isIgnored("doc/frotz", false));
    try testing.expect(!gi.isIgnored("other/doc/frotz", false));
}

test "unit: GitIgnore glob wildcards question mark and character classes" {
    const gi = GitIgnore.parse("app-?.log\nfile[0-9].txt\n*[!a-z].bin\n");
    try testing.expect(gi.isIgnored("app-1.log", false));
    try testing.expect(gi.isIgnored("app-a.log", false));
    try testing.expect(!gi.isIgnored("app-12.log", false));

    try testing.expect(gi.isIgnored("file0.txt", false));
    try testing.expect(gi.isIgnored("file9.txt", false));
    try testing.expect(!gi.isIgnored("fileA.txt", false));

    try testing.expect(gi.isIgnored("data1.bin", false));
    try testing.expect(!gi.isIgnored("dataa.bin", false));
}

test "unit: GitIgnore handles unlimited number of rules without allocation" {
    var buf: [65536]u8 = undefined;
    var pos: usize = 0;
    for (0..1000) |i| {
        const line = try std.fmt.bufPrint(buf[pos..], "pattern_{d}.txt\n", .{i});
        pos += line.len;
    }
    const gi = GitIgnore.parse(buf[0..pos]);
    try testing.expect(gi.isIgnored("pattern_0.txt", false));
    try testing.expect(gi.isIgnored("pattern_500.txt", false));
    try testing.expect(gi.isIgnored("pattern_999.txt", false));
    try testing.expect(!gi.isIgnored("pattern_1000.txt", false));
}
