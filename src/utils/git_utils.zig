const std = @import("std");

pub const git = @import("git/root.zig");

// Re-export all declarations from git/root.zig
pub const GitHeadInfo = git.GitHeadInfo;
pub const GitStatusInfo = git.GitStatusInfo;
pub const GitCommitResult = git.GitCommitResult;
pub const GitStateType = git.GitStateType;
pub const GitStateResult = git.GitStateResult;

pub const findGitDir = git.findGitDir;
pub const findRepoRoot = git.findRepoRoot;
pub const gitDirToRepoRoot = git.gitDirToRepoRoot;
pub const gitDirToCommonDir = git.gitDirToCommonDir;
pub const resolveRepoRoot = git.resolveRepoRoot;
pub const parseGitDirPointer = git.parseGitDirPointer;

pub const findTagForHash = git.findTagForHash;

pub const getGitState = git.getGitState;

pub const getGitStatus = git.getGitStatus;
pub const getGitStatusForDir = git.getGitStatusForDir;
pub const writeNotInGitRepo = git.writeNotInGitRepo;
pub const resolveBranch = git.resolveBranch;
pub const resolveCommit = git.resolveCommit;
pub const getIndexEntryCount = git.getIndexEntryCount;
pub const GitFileCollector = git.GitFileCollector;
pub const collectDetailedGitFiles = git.collectDetailedGitFiles;

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

    const info = getGitStatus(io, git_dir);
    _ = info;
}
