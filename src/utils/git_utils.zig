const std = @import("std");

/// Parses the contents of a .git/HEAD file and extracts the branch name or short commit SHA.
pub fn parseHeadContent(content_raw: []const u8) ?[]const u8 {
    const content = std.mem.trim(u8, content_raw, " \t\r\n");
    if (content.len == 0) return null;

    if (std.mem.startsWith(u8, content, "ref: refs/heads/")) {
        return content["ref: refs/heads/".len..];
    } else if (std.mem.startsWith(u8, content, "ref: refs/")) {
        return content["ref: refs/".len..];
    }

    // Check if it's a raw commit hash (SHA-1: 40 hex chars, or SHA-256: 64 hex chars)
    if (content.len >= 7) {
        var is_hex = true;
        for (content[0..7]) |c| {
            if (!std.ascii.isHex(c)) {
                is_hex = false;
                break;
            }
        }
        if (is_hex) {
            return content[0..7];
        }
    }

    return content;
}

/// Parses a .git pointer file (common in git worktrees and submodules) with format "gitdir: <path>".
pub fn parseGitDirPointer(content_raw: []const u8) ?[]const u8 {
    const content = std.mem.trim(u8, content_raw, " \t\r\n");
    if (std.mem.startsWith(u8, content, "gitdir:")) {
        return std.mem.trim(u8, content["gitdir:".len..], " \t\r\n");
    }
    return null;
}

/// Locates the .git directory or gitdir pointer by searching the current directory and its ancestors.
pub fn findGitDir(
    io: std.Io,
    cwd: []const u8,
    out_buf: *[std.fs.max_path_bytes]u8,
) ?[]const u8 {
    var current: []const u8 = cwd;

    while (current.len > 0) {
        // Build path: "<current>/.git"
        const git_path = std.fmt.bufPrint(out_buf, "{s}/.git", .{current}) catch return null;

        // Try opening .git as a directory or file
        if (std.Io.Dir.openDirAbsolute(io, git_path, .{})) |dir| {
            var d = dir;
            d.close(io);
            return git_path;
        } else |_| {
            // Check if .git is a file (worktree or submodule pointer)
            if (std.Io.Dir.openFileAbsolute(io, git_path, .{})) |file| {
                var stream_buf: [512]u8 = undefined;
                var file_reader = file.reader(io, &stream_buf);
                var content_buf: [512]u8 = undefined;
                const bytes_read = file_reader.interface.readSliceShort(&content_buf) catch 0;
                file.close(io);

                if (bytes_read > 0) {
                    if (parseGitDirPointer(content_buf[0..bytes_read])) |target_gitdir| {
                        if (std.fs.path.isAbsolute(target_gitdir)) {
                            return std.fmt.bufPrint(out_buf, "{s}", .{target_gitdir}) catch null;
                        } else {
                            return std.fmt.bufPrint(out_buf, "{s}/{s}", .{ current, target_gitdir }) catch null;
                        }
                    }
                }
            } else |_| {}
        }

        const parent = std.fs.path.dirname(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break;
        current = parent;
    }

    return null;
}

/// Resolves the current git branch name or short commit SHA from cwd.
pub fn getGitBranch(
    io: std.Io,
    cwd: []const u8,
    git_dir_buf: *[std.fs.max_path_bytes]u8,
    head_content_buf: *[512]u8,
) ?[]const u8 {
    const git_dir = findGitDir(io, cwd, git_dir_buf) orelse return null;

    var head_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const head_path = std.fmt.bufPrint(&head_path_buf, "{s}/HEAD", .{git_dir}) catch return null;

    const file = std.Io.Dir.openFileAbsolute(io, head_path, .{}) catch return null;
    defer file.close(io);

    var stream_buf: [512]u8 = undefined;
    var file_reader = file.reader(io, &stream_buf);

    const bytes_read = file_reader.interface.readSliceShort(head_content_buf) catch return null;
    if (bytes_read == 0) return null;

    return parseHeadContent(head_content_buf[0..bytes_read]);
}

pub const GitStatusInfo = struct {
    staged: bool = false,
    modified: bool = false,
    untracked: bool = false,
    renamed: bool = false,
    deleted: bool = false,
    stashed: bool = false,
    conflicted: bool = false,
    ahead: usize = 0,
    behind: usize = 0,

    pub fn hasAnyStatus(self: GitStatusInfo) bool {
        inline for (@typeInfo(GitStatusInfo).@"struct".fields) |field| {
            if (field.type == bool) {
                if (@field(self, field.name)) return true;
            } else if (field.type == usize or field.type == u64 or field.type == u32) {
                if (@field(self, field.name) > 0) return true;
            }
        }
        return false;
    }
};

/// Parses git status --porcelain=v2 output and extracts status flags and ahead/behind counts.
pub fn parseGitStatusPorcelainV2(output: []const u8) GitStatusInfo {
    var info = GitStatusInfo{};
    var line_iter = std.mem.splitScalar(u8, output, '\n');

    while (line_iter.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \r\t");
        if (line.len == 0) continue;

        if (std.mem.startsWith(u8, line, "# branch.ab ")) {
            const ab = line["# branch.ab ".len..];
            if (std.mem.startsWith(u8, ab, "+")) {
                var space_idx: ?usize = null;
                for (ab, 0..) |c, i| {
                    if (c == ' ') {
                        space_idx = i;
                        break;
                    }
                }
                if (space_idx) |sp| {
                    const ahead_str = ab[1..sp];
                    info.ahead = std.fmt.parseInt(usize, ahead_str, 10) catch 0;
                    const rest = ab[sp + 1 ..];
                    if (std.mem.startsWith(u8, rest, "-")) {
                        info.behind = std.fmt.parseInt(usize, rest[1..], 10) catch 0;
                    }
                }
            }
        } else if (std.mem.startsWith(u8, line, "# stash ")) {
            const stash_str = line["# stash ".len..];
            const stash_count = std.fmt.parseInt(usize, stash_str, 10) catch 0;
            if (stash_count > 0) info.stashed = true;
        } else if (std.mem.startsWith(u8, line, "1 ")) {
            if (line.len >= 4) {
                const staged_char = line[2];
                const worktree_char = line[3];

                if (staged_char != '.') {
                    info.staged = true;
                    if (staged_char == 'R' or staged_char == 'C') info.renamed = true;
                    if (staged_char == 'D') info.deleted = true;
                }
                if (worktree_char != '.') {
                    if (worktree_char == 'M' or worktree_char == 'T' or worktree_char == 'A') info.modified = true;
                    if (worktree_char == 'D') info.deleted = true;
                    if (worktree_char == 'R') info.renamed = true;
                }
            }
        } else if (std.mem.startsWith(u8, line, "2 ")) {
            if (line.len >= 4) {
                const staged_char = line[2];
                const worktree_char = line[3];
                info.renamed = true;
                if (staged_char != '.') info.staged = true;
                if (worktree_char != '.') info.modified = true;
                if (staged_char == 'D' or worktree_char == 'D') info.deleted = true;
            }
        } else if (std.mem.startsWith(u8, line, "u ")) {
            info.conflicted = true;
        } else if (std.mem.startsWith(u8, line, "? ")) {
            info.untracked = true;
        }
    }

    return info;
}

/// Retrieves git status info by running `git --no-optional-locks status --porcelain=v2 --branch --show-stash`
/// to accurately detect tracked/untracked, modified, staged, renamed, deleted, conflicted, stashed, and ahead/behind counts.
pub fn getGitStatus(io: std.Io, git_dir: []const u8, branch_name: ?[]const u8) GitStatusInfo {
    _ = branch_name;
    const work_dir = std.fs.path.dirname(git_dir) orelse ".";
    return getGitStatusForDir(io, work_dir, git_dir);
}

/// Runs git status command in the specified working directory.
pub fn getGitStatusForDir(io: std.Io, work_dir: []const u8, git_dir: ?[]const u8) GitStatusInfo {
    _ = git_dir;
    var child = std.process.spawn(io, .{
        .argv = &[_][]const u8{
            "git",
            "--no-optional-locks",
            "status",
            "--porcelain=v2",
            "--branch",
            "--show-stash",
        },
        .cwd = .{ .path = work_dir },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch {
        return .{};
    };
    defer child.kill(io);

    var buf: [16 * 1024]u8 = undefined;
    var stream_buf: [1024]u8 = undefined;
    var reader = child.stdout.?.reader(io, &stream_buf);
    const n = reader.interface.readSliceShort(&buf) catch 0;
    const term = child.wait(io) catch return .{};

    switch (term) {
        .exited => |code| if (code != 0) return .{},
        else => return .{},
    }

    return parseGitStatusPorcelainV2(buf[0..n]);
}

/// Checks if there are any untracked files in the repository by querying git status.
pub fn checkUntracked(io: std.Io, work_dir: []const u8, git_dir: []const u8) bool {
    const status = getGitStatusForDir(io, work_dir, git_dir);
    return status.untracked;
}

pub const GitCommitResult = struct {
    hash: []const u8 = "",
    tag: []const u8 = "",
    is_detached: bool = false,
};

/// Resolves commit hash and detached state from .git directory.
pub fn getGitCommit(
    io: std.Io,
    git_dir: []const u8,
    head_content_buf: *[512]u8,
    ref_content_buf: *[512]u8,
) ?GitCommitResult {
    var head_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const head_path = std.fmt.bufPrint(&head_path_buf, "{s}/HEAD", .{git_dir}) catch return null;

    const file = std.Io.Dir.openFileAbsolute(io, head_path, .{}) catch return null;
    defer file.close(io);

    var stream_buf: [512]u8 = undefined;
    var file_reader = file.reader(io, &stream_buf);
    const bytes_read = file_reader.interface.readSliceShort(head_content_buf) catch return null;
    if (bytes_read == 0) return null;

    const raw_head = std.mem.trim(u8, head_content_buf[0..bytes_read], " \t\r\n");

    if (std.mem.startsWith(u8, raw_head, "ref: refs/heads/")) {
        const branch_ref = raw_head["ref: ".len..]; // e.g. "refs/heads/main"
        var ref_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const ref_path = std.fmt.bufPrint(&ref_path_buf, "{s}/{s}", .{ git_dir, branch_ref }) catch return null;

        if (std.Io.Dir.openFileAbsolute(io, ref_path, .{})) |ref_file| {
            defer ref_file.close(io);
            var ref_stream_buf: [512]u8 = undefined;
            var ref_reader = ref_file.reader(io, &ref_stream_buf);
            const ref_bytes = ref_reader.interface.readSliceShort(ref_content_buf) catch 0;
            if (ref_bytes >= 7) {
                const sha = std.mem.trim(u8, ref_content_buf[0..ref_bytes], " \t\r\n");
                return GitCommitResult{
                    .hash = sha,
                    .is_detached = false,
                };
            }
        } else |_| {}

        return GitCommitResult{
            .hash = "",
            .is_detached = false,
        };
    } else if (raw_head.len >= 7) {
        // Detached HEAD raw commit SHA
        return GitCommitResult{
            .hash = raw_head,
            .is_detached = true,
        };
    }

    return null;
}

pub const GitStateType = enum {
    none,
    rebase,
    merge,
    revert,
    cherry_pick,
    bisect,
    am,
    am_or_rebase,
};

pub const GitStateResult = struct {
    state_type: GitStateType = .none,
    progress_current: []const u8 = "",
    progress_total: []const u8 = "",
};

/// Reads a short text file (like msgnum, end) into a slice.
fn readSmallFile(io: std.Io, path: []const u8, buf: []u8) ?[]const u8 {
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return null;
    defer file.close(io);
    var stream_buf: [256]u8 = undefined;
    var reader = file.reader(io, &stream_buf);
    const n = reader.interface.readSliceShort(buf) catch return null;
    if (n == 0) return null;
    return std.mem.trim(u8, buf[0..n], " \t\r\n");
}

/// Detects the active git operation state (REBASING, MERGING, CHERRY-PICKING, REVERTING, etc.).
pub fn getGitState(
    io: std.Io,
    git_dir: []const u8,
    cur_step_buf: *[32]u8,
    total_step_buf: *[32]u8,
) GitStateResult {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;

    // 1. Rebase merge
    const rebase_merge = std.fmt.bufPrint(&path_buf, "{s}/rebase-merge", .{git_dir}) catch return .{};
    if (std.Io.Dir.openDirAbsolute(io, rebase_merge, .{})) |dir| {
        var d = dir;
        d.close(io);

        var cur: []const u8 = "";
        var total: []const u8 = "";

        const msgnum_path = std.fmt.bufPrint(&path_buf, "{s}/rebase-merge/msgnum", .{git_dir}) catch "";
        if (msgnum_path.len > 0) {
            if (readSmallFile(io, msgnum_path, cur_step_buf)) |val| {
                cur = val;
            }
        }

        const end_path = std.fmt.bufPrint(&path_buf, "{s}/rebase-merge/end", .{git_dir}) catch "";
        if (end_path.len > 0) {
            if (readSmallFile(io, end_path, total_step_buf)) |val| {
                total = val;
            }
        }

        return GitStateResult{
            .state_type = .rebase,
            .progress_current = cur,
            .progress_total = total,
        };
    } else |_| {}

    // 2. Rebase apply
    const rebase_apply = std.fmt.bufPrint(&path_buf, "{s}/rebase-apply", .{git_dir}) catch return .{};
    if (std.Io.Dir.openDirAbsolute(io, rebase_apply, .{})) |dir| {
        var d = dir;
        d.close(io);

        var is_am = false;
        const applying_path = std.fmt.bufPrint(&path_buf, "{s}/rebase-apply/applying", .{git_dir}) catch "";
        if (applying_path.len > 0) {
            if (std.Io.Dir.openFileAbsolute(io, applying_path, .{})) |f| {
                f.close(io);
                is_am = true;
            } else |_| {}
        }

        var cur: []const u8 = "";
        var total: []const u8 = "";

        const next_path = std.fmt.bufPrint(&path_buf, "{s}/rebase-apply/next", .{git_dir}) catch "";
        if (next_path.len > 0) {
            if (readSmallFile(io, next_path, cur_step_buf)) |val| {
                cur = val;
            }
        }

        const last_path = std.fmt.bufPrint(&path_buf, "{s}/rebase-apply/last", .{git_dir}) catch "";
        if (last_path.len > 0) {
            if (readSmallFile(io, last_path, total_step_buf)) |val| {
                total = val;
            }
        }

        return GitStateResult{
            .state_type = if (is_am) .am else .rebase,
            .progress_current = cur,
            .progress_total = total,
        };
    } else |_| {}

    // 3. Merge
    const merge_head = std.fmt.bufPrint(&path_buf, "{s}/MERGE_HEAD", .{git_dir}) catch return .{};
    if (std.Io.Dir.openFileAbsolute(io, merge_head, .{})) |f| {
        f.close(io);
        return GitStateResult{ .state_type = .merge };
    } else |_| {}

    // 4. Cherry-pick
    const cherry_pick_head = std.fmt.bufPrint(&path_buf, "{s}/CHERRY_PICK_HEAD", .{git_dir}) catch return .{};
    if (std.Io.Dir.openFileAbsolute(io, cherry_pick_head, .{})) |f| {
        f.close(io);
        return GitStateResult{ .state_type = .cherry_pick };
    } else |_| {}

    // 5. Revert
    const revert_head = std.fmt.bufPrint(&path_buf, "{s}/REVERT_HEAD", .{git_dir}) catch return .{};
    if (std.Io.Dir.openFileAbsolute(io, revert_head, .{})) |f| {
        f.close(io);
        return GitStateResult{ .state_type = .revert };
    } else |_| {}

    // 6. Bisect
    const bisect_log = std.fmt.bufPrint(&path_buf, "{s}/BISECT_LOG", .{git_dir}) catch return .{};
    if (std.Io.Dir.openFileAbsolute(io, bisect_log, .{})) |f| {
        f.close(io);
        return GitStateResult{ .state_type = .bisect };
    } else |_| {}

    return GitStateResult{};
}

pub const GitMetricsResult = struct {
    added: usize = 0,
    deleted: usize = 0,
};

test "parseHeadContent on regular branch" {
    const raw = "ref: refs/heads/main\n";
    try std.testing.expectEqualStrings("main", parseHeadContent(raw).?);

    const nested = "ref: refs/heads/feature/auth-v2\n";
    try std.testing.expectEqualStrings("feature/auth-v2", parseHeadContent(nested).?);
}

test "parseHeadContent on detached HEAD SHA-1" {
    const raw = "4cd65cc6c714604db0f7a6f6df0b6b66a7620ce0\n";
    try std.testing.expectEqualStrings("4cd65cc", parseHeadContent(raw).?);
}

test "parseGitDirPointer worktree" {
    const raw = "gitdir: /home/user/project/.git/worktrees/feat\n";
    try std.testing.expectEqualStrings("/home/user/project/.git/worktrees/feat", parseGitDirPointer(raw).?);
}

test "GitStatusInfo hasAnyStatus" {
    var info = GitStatusInfo{};
    try std.testing.expectEqual(false, info.hasAnyStatus());

    info.modified = true;
    try std.testing.expectEqual(true, info.hasAnyStatus());
}

test "parseGitStatusPorcelainV2 parses branch and changed files" {
    const output =
        \\# branch.oid 5a9ce44ce1fa3fe29f7341445e332fca52db6e14
        \\# branch.head main
        \\# branch.upstream origin/main
        \\# branch.ab +4 -2
        \\1 .M N... 100644 100644 100644 734134628fce61f6c65a366769ec4819b205b950 734134628fce61f6c65a366769ec4819b205b950 README.md
        \\1 M. N... 100644 100644 100644 734134628fce61f6c65a366769ec4819b205b950 734134628fce61f6c65a366769ec4819b205b950 file2.zig
        \\? src/engine/context.zig
        \\u unmerged.txt
        \\
    ;

    const info = parseGitStatusPorcelainV2(output);
    try std.testing.expectEqual(@as(usize, 4), info.ahead);
    try std.testing.expectEqual(@as(usize, 2), info.behind);
    try std.testing.expect(info.modified);
    try std.testing.expect(info.staged);
    try std.testing.expect(info.untracked);
    try std.testing.expect(info.conflicted);
    try std.testing.expect(info.hasAnyStatus());
}

test "GitStatusInfo all flags verified" {
    var info = GitStatusInfo{
        .staged = true,
        .modified = true,
        .untracked = true,
        .renamed = true,
        .deleted = true,
        .stashed = true,
        .conflicted = true,
        .ahead = 3,
        .behind = 1,
    };

    try std.testing.expect(info.hasAnyStatus());
    try std.testing.expect(info.staged);
    try std.testing.expect(info.modified);
    try std.testing.expect(info.untracked);
    try std.testing.expect(info.renamed);
    try std.testing.expect(info.deleted);
    try std.testing.expect(info.stashed);
    try std.testing.expectEqual(@as(usize, 3), info.ahead);
    try std.testing.expectEqual(@as(usize, 1), info.behind);
}

test "parseGitStatusPorcelainV2 with stash and renames" {
    const output =
        \\# branch.oid 5a9ce44ce1fa3fe29f7341445e332fca52db6e14
        \\# branch.head main
        \\# branch.upstream origin/main
        \\# branch.ab +0 -0
        \\# stash 2
        \\2 R. N... 100644 100644 100644 734134628fce61f6c65a366769ec4819b205b950 734134628fce61f6c65a366769ec4819b205b950 R100 new_name.zig old_name.zig
        \\1 D. N... 100644 000000 000000 734134628fce61f6c65a366769ec4819b205b950 0000000000000000000000000000000000000000 deleted.zig
        \\? untracked_file.txt
        \\
    ;

    const info = parseGitStatusPorcelainV2(output);
    try std.testing.expect(info.stashed);
    try std.testing.expect(info.renamed);
    try std.testing.expect(info.staged);
    try std.testing.expect(info.deleted);
    try std.testing.expect(info.untracked);
}

test "getGitStatus live repo execution" {
    const io = std.testing.io;
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    const cwd = cwd_buf[0..cwd_len];

    var git_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const git_dir = findGitDir(io, cwd, &git_dir_buf) orelse return;

    var head_buf: [512]u8 = undefined;
    const branch = getGitBranch(io, cwd, &git_dir_buf, &head_buf);
    const info = getGitStatus(io, git_dir, branch);

    try std.testing.expect(info.hasAnyStatus());
}

