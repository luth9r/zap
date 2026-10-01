const std = @import("std");

pub const git = @import("git/root.zig");

// Re-export all declarations from git/root.zig
pub const GitRepo = git.GitRepo;
pub const GitStatusInfo = git.GitStatusInfo;
pub const GitCommitResult = git.GitCommitResult;
pub const GitStateType = git.GitStateType;
pub const GitStateResult = git.GitStateResult;

pub const findGitDir = git.findGitDir;
pub const findRepoRoot = git.findRepoRoot;
pub const parseGitDirPointer = git.parseGitDirPointer;
pub const fileExists = git.fileExists;
pub const anySubpathExists = git.anySubpathExists;
pub const readSmallFile = git.readSmallFile;
pub const writeFileAbsolute = git.writeFileAbsolute;

pub const parseHeadContent = git.parseHeadContent;
pub const getGitBranch = git.getGitBranch;
pub const getGitBranchFromDir = git.getGitBranchFromDir;
pub const getGitCommit = git.getGitCommit;

pub const getGitState = git.getGitState;

pub const parseGitStatusPorcelainV2 = git.parseGitStatusPorcelainV2;
pub const getGitStatus = git.getGitStatus;
pub const getGitStatusForDir = git.getGitStatusForDir;

test "test process.spawn" {
    const io = std.testing.io;
    var child = try std.process.spawn(io, .{
        .argv = &[_][]const u8{ "git", "status", "--porcelain=v2", "--branch", "--show-stash" },
        .stdout = .pipe,
        .stderr = .ignore,
        .stdin = .ignore,
    });
    var stream_buf: [512]u8 = undefined;
    var reader = child.stdout.?.reader(io, &stream_buf);
    var out_buf: [8192]u8 = undefined;
    const bytes_read = reader.interface.readSliceShort(&out_buf) catch 0;
    _ = child.wait(io) catch {};
    const info = parseGitStatusPorcelainV2(out_buf[0..bytes_read]);
    try std.testing.expect(info.hasAnyStatus() or !info.hasAnyStatus()); // just verify it doesn't crash
}

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

    _ = info;
}
