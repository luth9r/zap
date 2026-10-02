const std = @import("std");

pub const fs = @import("../fs.zig");
pub const dir = @import("dir.zig");
pub const refs = @import("refs.zig");
pub const state = @import("state.zig");
pub const ignore = @import("ignore.zig");
pub const GitIgnore = ignore.GitIgnore;

// Status flags and info
pub const GitStatusInfo = struct {
    staged: bool = false,
    modified: bool = false,
    untracked: bool = false,
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

// Re-export common types
pub const GitCommitResult = refs.GitCommitResult;
pub const GitStateType = state.GitStateType;
pub const GitStateResult = state.GitStateResult;

// Re-export standalone utility functions
pub const findGitDir = dir.findGitDir;
pub const findRepoRoot = dir.findRepoRoot;
pub const gitDirToRepoRoot = dir.gitDirToRepoRoot;
pub const parseGitDirPointer = dir.parseGitDirPointer;
pub const fileExists = fs.fileExists;
pub const anySubpathExists = fs.anySubpathExists;
pub const readSmallFile = fs.readSmallFile;
pub const writeFileAbsolute = fs.writeFileAbsolute;

pub const parseHeadContent = refs.parseHeadContent;
pub const getGitBranch = refs.getGitBranch;
pub const getGitBranchFromDir = refs.getGitBranchFromDir;
pub const getGitCommit = refs.getGitCommit;

pub const getGitState = state.getGitState;

pub const ahead_behind = @import("ahead_behind.zig");
pub const index = @import("index.zig");
pub const getAheadBehind = ahead_behind.getAheadBehind;
pub const scanGitIndex = index.scanGitIndex;

/// Retrieves git status info for the repository by invoking git child process.
pub fn getGitStatus(io: std.Io, git_dir: []const u8, branch_name: ?[]const u8) GitStatusInfo {
    const work_dir = dir.gitDirToRepoRoot(git_dir);
    return getGitStatusForDir(io, work_dir, git_dir, branch_name);
}

/// Computes git status natively in pure Zig without creating any subprocesses.
pub fn getGitStatusForDir(
    io: std.Io,
    work_dir: []const u8,
    git_dir_opt: ?[]const u8,
    branch_name_opt: ?[]const u8,
) GitStatusInfo {
    var info = GitStatusInfo{};

    var git_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const git_dir = git_dir_opt orelse findGitDir(io, work_dir, &git_dir_buf) orelse return info;
    const repo_root = dir.gitDirToRepoRoot(git_dir);

    // 1. Stashed changes check
    if (refs.hasStash(io, git_dir)) {
        info.stashed = true;
    }

    // 2. Ahead / Behind / Diverged check
    var branch_buf: [512]u8 = undefined;
    const branch_name = branch_name_opt orelse refs.getGitBranchFromDir(io, git_dir, &branch_buf);
    if (branch_name) |b_name| {
        const ab = ahead_behind.getAheadBehind(io, git_dir, b_name);
        info.ahead = ab.ahead;
        info.behind = ab.behind;
    }

    // 3. Git merge / conflict state check
    var cur_buf: [32]u8 = undefined;
    var total_buf: [32]u8 = undefined;
    const git_state = state.getGitState(io, git_dir, &cur_buf, &total_buf);
    if (git_state.state_type == .merge and fs.anySubpathExists(io, git_dir, &.{"MERGE_HEAD"})) {
        info.conflicted = true;
    }

    // 4. Index scan: streaming scan detects modified, deleted, conflicted, and staged files
    const index_res = index.scanGitIndex(io, git_dir, repo_root);
    if (index_res.modified) info.modified = true;
    if (index_res.deleted) info.deleted = true;
    if (index_res.conflicted) info.conflicted = true;
    if (index_res.staged) info.staged = true;

    // 5. Untracked files scan with deep BFS directory traversal and .gitignore support
    var gitignore = GitIgnore{};
    var gitignore_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var gi_content_buf: [16384]u8 = undefined;
    if (std.fmt.bufPrint(&gitignore_path_buf, "{s}/.gitignore", .{repo_root}) catch null) |gi_path| {
        if (fs.readSmallFile(io, gi_path, &gi_content_buf)) |content| {
            gitignore = GitIgnore.parse(content);
        }
    }

    var idx_scanner = index.GitIndexScanner.open(io, git_dir);
    defer if (idx_scanner) |*s| s.close();

    const MaxQueue = 32;
    var queue_buf: [MaxQueue][std.fs.max_path_bytes]u8 = undefined;
    var queue_len: [MaxQueue]usize = undefined;
    var q_head: usize = 0;
    var q_tail: usize = 0;

    queue_len[0] = 0;
    q_tail = 1;

    var total_entries_scanned: usize = 0;

    while (q_head < q_tail and !info.untracked and total_entries_scanned < 1000) {
        const cur_rel = queue_buf[q_head][0..queue_len[q_head]];
        q_head += 1;

        var full_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
        const full_dir_path = if (cur_rel.len == 0)
            repo_root
        else
            std.fmt.bufPrint(&full_dir_buf, "{s}/{s}", .{ repo_root, cur_rel }) catch continue;

        var d_handle = if (std.fs.path.isAbsolute(full_dir_path))
            std.Io.Dir.openDirAbsolute(io, full_dir_path, .{ .iterate = true }) catch continue
        else
            std.Io.Dir.cwd().openDir(io, full_dir_path, .{ .iterate = true }) catch continue;
        defer d_handle.close(io);

        var it = d_handle.iterate();
        while (it.next(io) catch null) |entry| {
            total_entries_scanned += 1;
            if (total_entries_scanned > 1000) break;

            if (cur_rel.len == 0 and (std.mem.eql(u8, entry.name, ".git") or std.mem.eql(u8, entry.name, ".gitignore"))) continue;
            if (std.mem.eql(u8, entry.name, ".git")) continue;

            var rel_entry_buf: [std.fs.max_path_bytes]u8 = undefined;
            const rel_entry = if (cur_rel.len == 0)
                entry.name
            else
                std.fmt.bufPrint(&rel_entry_buf, "{s}/{s}", .{ cur_rel, entry.name }) catch continue;

            const is_directory = (entry.kind == .directory);
            if (gitignore.isIgnored(rel_entry, is_directory)) continue;

            if (!is_directory) {
                const in_idx = if (idx_scanner) |*s| s.contains(rel_entry, false) else false;
                if (!in_idx) {
                    info.untracked = true;
                    break;
                }
            } else {
                const in_idx = if (idx_scanner) |*s| s.contains(rel_entry, true) else false;
                if (!in_idx) {
                    info.untracked = true;
                    break;
                }
                if (q_tail < MaxQueue) {
                    @memcpy(queue_buf[q_tail][0..rel_entry.len], rel_entry);
                    queue_len[q_tail] = rel_entry.len;
                    q_tail += 1;
                }
            }
        }
    }

    return info;
}
