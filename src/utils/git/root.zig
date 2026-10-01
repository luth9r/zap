const std = @import("std");

pub const fs = @import("../fs.zig");
pub const dir = @import("dir.zig");
pub const refs = @import("refs.zig");
pub const state = @import("state.zig");

// Status flags and info
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

// Re-export common types
pub const GitCommitResult = refs.GitCommitResult;
pub const GitStateType = state.GitStateType;
pub const GitStateResult = state.GitStateResult;

// Re-export standalone utility functions
pub const findGitDir = dir.findGitDir;
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

/// Retrieves git status info for the repository by invoking git child process.
pub fn getGitStatus(io: std.Io, git_dir: []const u8, branch_name: ?[]const u8) GitStatusInfo {
    const work_dir = std.fs.path.dirname(git_dir) orelse ".";
    return getGitStatusForDir(io, work_dir, git_dir, branch_name);
}

/// Computes git status for the given work directory by spawning git status child process.
pub fn getGitStatusForDir(
    io: std.Io,
    work_dir: []const u8,
    git_dir_opt: ?[]const u8,
    branch_name: ?[]const u8,
) GitStatusInfo {
    _ = git_dir_opt;
    _ = branch_name;
    var child = std.process.spawn(io, .{
        .argv = &[_][]const u8{ "git", "status", "--porcelain=v2", "--branch", "--show-stash" },
        .cwd = .{ .path = work_dir },
        .stdout = .pipe,
        .stderr = .ignore,
        .stdin = .ignore,
    }) catch return .{};

    var stream_buf: [512]u8 = undefined;
    var reader = child.stdout.?.reader(io, &stream_buf);
    var out_buf: [65536]u8 = undefined;
    var total_read: usize = 0;

    while (total_read < out_buf.len) {
        const n = reader.interface.readSliceShort(out_buf[total_read..]) catch 0;
        if (n == 0) break;
        total_read += n;
    }

    _ = child.wait(io) catch {};

    return parseGitStatusPorcelainV2(out_buf[0..total_read]);
}
