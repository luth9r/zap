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

/// High-level struct representing an opened Git repository.
pub const GitRepo = struct {
    io: std.Io,
    work_dir: []const u8,
    git_dir: []const u8,

    pub fn open(io: std.Io, cwd: []const u8, git_dir_buf: *[std.fs.max_path_bytes]u8) ?GitRepo {
        const git_dir = findGitDir(io, cwd, git_dir_buf) orelse return null;
        const work_dir = std.fs.path.dirname(git_dir) orelse cwd;
        return .{
            .io = io,
            .work_dir = work_dir,
            .git_dir = git_dir,
        };
    }

    pub fn getStatus(self: GitRepo, branch_name: ?[]const u8) GitStatusInfo {
        return getGitStatusForDir(self.io, self.work_dir, self.git_dir, branch_name);
    }

    pub fn getBranch(self: GitRepo, head_buf: *[512]u8) ?[]const u8 {
        var git_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
        return getGitBranch(self.io, self.work_dir, &git_dir_buf, head_buf);
    }

    pub fn getState(self: GitRepo, cur_step_buf: *[32]u8, total_step_buf: *[32]u8) GitStateResult {
        return getGitState(self.io, self.git_dir, cur_step_buf, total_step_buf);
    }
};


/// Retrieves git status info for the repository by invoking git child process.
pub fn getGitStatus(io: std.Io, git_dir: []const u8, branch_name: ?[]const u8) GitStatusInfo {
    const work_dir = std.fs.path.dirname(git_dir) orelse ".";
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

    var repo_root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const repo_root = findRepoRoot(io, work_dir, &repo_root_buf) orelse work_dir;

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

    // 5. Untracked files scan with deep directory traversal and .gitignore support
    var gitignore = GitIgnore{};
    var gitignore_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (std.fmt.bufPrint(&gitignore_path_buf, "{s}/.gitignore", .{repo_root}) catch null) |gi_path| {
        var gi_content_buf: [4096]u8 = undefined;
        if (fs.readSmallFile(io, gi_path, &gi_content_buf)) |content| {
            gitignore = GitIgnore.parse(content);
        }
    }

    var root_dir = if (std.fs.path.isAbsolute(repo_root))
        std.Io.Dir.openDirAbsolute(io, repo_root, .{ .iterate = true }) catch null
    else
        std.Io.Dir.cwd().openDir(io, repo_root, .{ .iterate = true }) catch null;

    if (root_dir) |*dir_handle| {
        defer dir_handle.close(io);
        var it = dir_handle.iterate();
        var dir_entries_scanned: usize = 0;

        while (it.next(io) catch null) |entry| {
            dir_entries_scanned += 1;
            if (dir_entries_scanned > 1000) break;

            if (std.mem.eql(u8, entry.name, ".git")) continue;
            if (std.mem.eql(u8, entry.name, ".gitignore")) continue;

            const is_directory = (entry.kind == .directory);
            if (gitignore.isIgnored(entry.name, is_directory)) continue;

            if (!is_directory) {
                if (!index.isPathInIndex(io, git_dir, entry.name, false)) {
                    info.untracked = true;
                    break;
                }
            } else {
                // Check if directory prefix exists in index
                if (!index.isPathInIndex(io, git_dir, entry.name, true)) {
                    info.untracked = true;
                    break;
                }

                // If directory is tracked, check inside for untracked files
                var sub_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
                if (std.fmt.bufPrint(&sub_dir_buf, "{s}/{s}", .{ repo_root, entry.name }) catch null) |sub_path| {
                    if (std.Io.Dir.openDirAbsolute(io, sub_path, .{ .iterate = true })) |sub_dir_handle| {
                        var sd = sub_dir_handle;
                        defer sd.close(io);
                        var sub_it = sd.iterate();
                        var sub_entries_scanned: usize = 0;

                        while (sub_it.next(io) catch null) |sub_entry| {
                            sub_entries_scanned += 1;
                            if (sub_entries_scanned > 200) break;

                            var rel_child_buf: [std.fs.max_path_bytes]u8 = undefined;
                            if (std.fmt.bufPrint(&rel_child_buf, "{s}/{s}", .{ entry.name, sub_entry.name }) catch null) |rel_child| {
                                const sub_is_dir = (sub_entry.kind == .directory);
                                if (gitignore.isIgnored(rel_child, sub_is_dir)) continue;
                                if (!index.isPathInIndex(io, git_dir, rel_child, sub_is_dir)) {
                                    info.untracked = true;
                                    break;
                                }
                            }
                        }
                        if (info.untracked) break;
                    } else |_| {}
                }
            }
        }
    }

    return info;
}
