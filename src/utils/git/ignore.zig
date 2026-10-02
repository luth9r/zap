const std = @import("std");
const testing = std.testing;

pub const GitIgnoreRule = struct {
    pattern: []const u8,
    is_dir_only: bool = false,
    is_negation: bool = false,
};

pub const max_rules = 64;

pub const GitIgnore = struct {
    rules: [max_rules]GitIgnoreRule = undefined,
    rule_count: usize = 0,

    pub fn parse(content: []const u8) GitIgnore {
        var res = GitIgnore{};
        var line_it = std.mem.splitScalar(u8, content, '\n');
        while (line_it.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;

            if (res.rule_count >= max_rules) break;

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

            // Strip leading '/' if present
            if (pattern.len > 0 and pattern[0] == '/') {
                pattern = pattern[1..];
            }

            res.rules[res.rule_count] = .{
                .pattern = pattern,
                .is_dir_only = is_dir_only,
                .is_negation = is_negation,
            };
            res.rule_count += 1;
        }
        return res;
    }

    pub fn isIgnored(self: GitIgnore, rel_path: []const u8, is_dir: bool) bool {
        if (rel_path.len == 0) return false;

        // Strip leading '/' or './'
        var path = rel_path;
        if (std.mem.startsWith(u8, path, "./")) {
            path = path[2..];
        } else if (path[0] == '/') {
            path = path[1..];
        }

        const base_name = std.fs.path.basename(path);
        var ignored = false;

        for (self.rules[0..self.rule_count]) |rule| {
            if (rule.is_dir_only and !is_dir) {
                // If rule is directory-only, check if any parent segment matches
                var it = std.mem.splitScalar(u8, path, '/');
                var matched_parent = false;
                while (it.next()) |segment| {
                    if (matchPattern(rule.pattern, segment)) {
                        matched_parent = true;
                        break;
                    }
                }
                if (matched_parent) {
                    ignored = !rule.is_negation;
                }
                continue;
            }

            // Match full relative path or basename
            if (matchPattern(rule.pattern, path) or matchPattern(rule.pattern, base_name)) {
                ignored = !rule.is_negation;
            }
        }

        return ignored;
    }

    fn matchPattern(pattern: []const u8, target: []const u8) bool {
        if (pattern.len == 0) return false;

        // Wildcard extension match: *.ext
        if (pattern.len >= 2 and pattern[0] == '*' and pattern[1] == '.') {
            const ext = pattern[1..]; // e.g. ".log"
            return std.mem.endsWith(u8, target, ext);
        }

        // Wildcard prefix match: prefix*
        if (pattern.len >= 2 and pattern[pattern.len - 1] == '*') {
            const prefix = pattern[0 .. pattern.len - 1];
            return std.mem.startsWith(u8, target, prefix);
        }

        // Exact match
        return std.mem.eql(u8, pattern, target);
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
    try testing.expectEqual(@as(usize, 2), gi.rule_count);
    try testing.expectEqualStrings("*.log", gi.rules[0].pattern);
    try testing.expectEqual(false, gi.rules[0].is_dir_only);
    try testing.expectEqualStrings("node_modules", gi.rules[1].pattern);
    try testing.expectEqual(true, gi.rules[1].is_dir_only);
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
