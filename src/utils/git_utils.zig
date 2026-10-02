const std = @import("std");

pub const git = @import("git/root.zig");

// Re-export all declarations from git/root.zig
pub const GitStatusInfo = git.GitStatusInfo;
pub const GitCommitResult = git.GitCommitResult;
pub const GitStateType = git.GitStateType;
pub const GitStateResult = git.GitStateResult;

pub const findGitDir = git.findGitDir;
pub const findRepoRoot = git.findRepoRoot;
pub const gitDirToRepoRoot = git.gitDirToRepoRoot;
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

pub const getGitStatus = git.getGitStatus;
pub const getGitStatusForDir = git.getGitStatusForDir;

test "unit: parseHeadContent on regular branch" {
    const raw = "ref: refs/heads/main\n";
    try std.testing.expectEqualStrings("main", parseHeadContent(raw).?);

    const nested = "ref: refs/heads/feature/auth-v2\n";
    try std.testing.expectEqualStrings("feature/auth-v2", parseHeadContent(nested).?);
}

test "unit: parseHeadContent on detached HEAD SHA-1" {
    const raw = "4cd65cc6c714604db0f7a6f6df0b6b66a7620ce0\n";
    try std.testing.expectEqualStrings("4cd65cc", parseHeadContent(raw).?);
}

test "unit: parseGitDirPointer worktree" {
    const raw = "gitdir: /home/user/project/.git/worktrees/feat\n";
    try std.testing.expectEqualStrings("/home/user/project/.git/worktrees/feat", parseGitDirPointer(raw).?);
}

test "unit: GitStatusInfo hasAnyStatus" {
    var info = GitStatusInfo{};
    try std.testing.expectEqual(false, info.hasAnyStatus());

    info.modified = true;
    try std.testing.expectEqual(true, info.hasAnyStatus());
}

test "unit: GitStatusInfo all flags verified" {
    var info = GitStatusInfo{
        .staged = true,
        .modified = true,
        .untracked = true,
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
    try std.testing.expect(info.deleted);
    try std.testing.expect(info.stashed);
    try std.testing.expectEqual(@as(usize, 3), info.ahead);
    try std.testing.expectEqual(@as(usize, 1), info.behind);
}

test "unit: getGitStatus live repo execution" {
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
