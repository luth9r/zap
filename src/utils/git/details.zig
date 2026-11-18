const std = @import("std");
const root = @import("root.zig");

pub const GitFileCollector = struct {
    pub const MaxEntries = 128;
    pub const MaxPathStorage = 16384;

    pub const PathList = struct {
        offsets: [MaxEntries]u16 = undefined,
        lens: [MaxEntries]u16 = undefined,
        count: usize = 0,
    };

    staged: PathList = .{},
    modified: PathList = .{},
    deleted: PathList = .{},
    renamed: PathList = .{},
    untracked: PathList = .{},
    conflicted: PathList = .{},

    modified_count: usize = 0,
    deleted_count: usize = 0,
    renamed_count: usize = 0,
    staged_count: usize = 0,
    untracked_count: usize = 0,
    conflicted_count: usize = 0,

    storage: [MaxPathStorage]u8 = undefined,
    storage_pos: usize = 0,

    fn appendToList(self: *GitFileCollector, list: *PathList, count_alias: *usize, path: []const u8) void {
        if (list.count >= MaxEntries) return;
        if (self.storage_pos + path.len > MaxPathStorage) return;
        const offset = self.storage_pos;
        @memcpy(self.storage[offset .. offset + path.len], path);
        self.storage_pos += path.len;
        list.offsets[list.count] = @intCast(offset);
        list.lens[list.count] = @intCast(path.len);
        list.count += 1;
        count_alias.* = list.count;
    }

    fn sliceFromList(self: *const GitFileCollector, list: *const PathList, idx: usize) []const u8 {
        const offset = list.offsets[idx];
        return self.storage[offset .. offset + list.lens[idx]];
    }

    pub fn addStaged(self: *GitFileCollector, path: []const u8) void {
        self.appendToList(&self.staged, &self.staged_count, path);
    }

    pub fn getStaged(self: *const GitFileCollector, idx: usize) []const u8 {
        return self.sliceFromList(&self.staged, idx);
    }

    pub fn addModified(self: *GitFileCollector, path: []const u8) void {
        self.appendToList(&self.modified, &self.modified_count, path);
    }

    pub fn getModified(self: *const GitFileCollector, idx: usize) []const u8 {
        return self.sliceFromList(&self.modified, idx);
    }

    pub fn addDeleted(self: *GitFileCollector, path: []const u8) void {
        self.appendToList(&self.deleted, &self.deleted_count, path);
    }

    pub fn getDeleted(self: *const GitFileCollector, idx: usize) []const u8 {
        return self.sliceFromList(&self.deleted, idx);
    }

    pub fn addRenamed(self: *GitFileCollector, path: []const u8) void {
        self.appendToList(&self.renamed, &self.renamed_count, path);
    }

    pub fn getRenamed(self: *const GitFileCollector, idx: usize) []const u8 {
        return self.sliceFromList(&self.renamed, idx);
    }

    pub fn addUntracked(self: *GitFileCollector, path: []const u8) void {
        self.appendToList(&self.untracked, &self.untracked_count, path);
    }

    pub fn getUntracked(self: *const GitFileCollector, idx: usize) []const u8 {
        return self.sliceFromList(&self.untracked, idx);
    }

    pub fn addConflicted(self: *GitFileCollector, path: []const u8) void {
        self.appendToList(&self.conflicted, &self.conflicted_count, path);
    }

    pub fn getConflicted(self: *const GitFileCollector, idx: usize) []const u8 {
        return self.sliceFromList(&self.conflicted, idx);
    }
};

/// Collects detailed lists of modified, deleted, conflicted, and untracked files
/// via `git status --porcelain=v2 --untracked-files=all`.
pub fn collectDetailedGitFiles(
    io: std.Io,
    git_dir: []const u8,
    repo_root: []const u8,
    collector: *GitFileCollector,
) root.GitStatusInfo {
    _ = git_dir;
    var info = root.GitStatusInfo{};
    _ = root.runGitStatusPorcelain(io, repo_root, true, &info, collector);
    return info;
}
