const std = @import("std");
const fs = @import("../fs.zig");
const index = @import("index.zig");
const ignore = @import("ignore.zig");
const GitIgnore = ignore.GitIgnore;

pub const GitFileCollector = struct {
    pub const MaxEntries = 128;
    pub const MaxPathStorage = 16384;

    modified_offsets: [MaxEntries]u16 = undefined,
    modified_lens: [MaxEntries]u16 = undefined,
    modified_count: usize = 0,

    deleted_offsets: [MaxEntries]u16 = undefined,
    deleted_lens: [MaxEntries]u16 = undefined,
    deleted_count: usize = 0,

    untracked_offsets: [MaxEntries]u16 = undefined,
    untracked_lens: [MaxEntries]u16 = undefined,
    untracked_count: usize = 0,

    conflicted_offsets: [MaxEntries]u16 = undefined,
    conflicted_lens: [MaxEntries]u16 = undefined,
    conflicted_count: usize = 0,

    storage: [MaxPathStorage]u8 = undefined,
    storage_pos: usize = 0,

    pub fn addModified(self: *GitFileCollector, path: []const u8) void {
        if (self.modified_count >= MaxEntries) return;
        if (self.storage_pos + path.len > MaxPathStorage) return;
        const offset = self.storage_pos;
        @memcpy(self.storage[offset .. offset + path.len], path);
        self.storage_pos += path.len;
        self.modified_offsets[self.modified_count] = @intCast(offset);
        self.modified_lens[self.modified_count] = @intCast(path.len);
        self.modified_count += 1;
    }

    pub fn getModified(self: *const GitFileCollector, idx: usize) []const u8 {
        const offset = self.modified_offsets[idx];
        const len = self.modified_lens[idx];
        return self.storage[offset .. offset + len];
    }

    pub fn addDeleted(self: *GitFileCollector, path: []const u8) void {
        if (self.deleted_count >= MaxEntries) return;
        if (self.storage_pos + path.len > MaxPathStorage) return;
        const offset = self.storage_pos;
        @memcpy(self.storage[offset .. offset + path.len], path);
        self.storage_pos += path.len;
        self.deleted_offsets[self.deleted_count] = @intCast(offset);
        self.deleted_lens[self.deleted_count] = @intCast(path.len);
        self.deleted_count += 1;
    }

    pub fn getDeleted(self: *const GitFileCollector, idx: usize) []const u8 {
        const offset = self.deleted_offsets[idx];
        const len = self.deleted_lens[idx];
        return self.storage[offset .. offset + len];
    }

    pub fn addUntracked(self: *GitFileCollector, path: []const u8) void {
        if (self.untracked_count >= MaxEntries) return;
        if (self.storage_pos + path.len > MaxPathStorage) return;
        const offset = self.storage_pos;
        @memcpy(self.storage[offset .. offset + path.len], path);
        self.storage_pos += path.len;
        self.untracked_offsets[self.untracked_count] = @intCast(offset);
        self.untracked_lens[self.untracked_count] = @intCast(path.len);
        self.untracked_count += 1;
    }

    pub fn getUntracked(self: *const GitFileCollector, idx: usize) []const u8 {
        const offset = self.untracked_offsets[idx];
        const len = self.untracked_lens[idx];
        return self.storage[offset .. offset + len];
    }

    pub fn addConflicted(self: *GitFileCollector, path: []const u8) void {
        if (self.conflicted_count >= MaxEntries) return;
        if (self.storage_pos + path.len > MaxPathStorage) return;
        const offset = self.storage_pos;
        @memcpy(self.storage[offset .. offset + path.len], path);
        self.storage_pos += path.len;
        self.conflicted_offsets[self.conflicted_count] = @intCast(offset);
        self.conflicted_lens[self.conflicted_count] = @intCast(path.len);
        self.conflicted_count += 1;
    }

    pub fn getConflicted(self: *const GitFileCollector, idx: usize) []const u8 {
        const offset = self.conflicted_offsets[idx];
        const len = self.conflicted_lens[idx];
        return self.storage[offset .. offset + len];
    }
};

fn readExact(reader: anytype, dest: []u8) bool {
    var total: usize = 0;
    while (total < dest.len) {
        const n = reader.interface.readSliceShort(dest[total..]) catch return false;
        if (n == 0) return false;
        total += n;
    }
    return true;
}

fn readByte(reader: anytype) ?u8 {
    var b: [1]u8 = undefined;
    const n = reader.interface.readSliceShort(&b) catch return null;
    if (n == 0) return null;
    return b[0];
}

fn readEntryName(reader: anytype, name_buf: *[std.fs.max_path_bytes]u8) ?[]const u8 {
    var name_len: usize = 0;
    while (name_len < name_buf.len) {
        const b = readByte(reader) orelse return null;
        if (b == 0) break;
        name_buf[name_len] = b;
        name_len += 1;
    }
    return name_buf[0..name_len];
}

fn skipEntryPadding(reader: anytype, header_len: usize, name_len: usize) bool {
    const raw_len = header_len + name_len + 1;
    const aligned_len = (raw_len + 7) & ~@as(usize, 7);
    const pad_needed = aligned_len - raw_len;
    if (pad_needed > 0) {
        var pad_buf: [8]u8 = undefined;
        return readExact(reader, pad_buf[0..pad_needed]);
    }
    return true;
}

/// Collects detailed lists of modified, deleted, conflicted, and untracked files
pub fn collectDetailedGitFiles(
    io: std.Io,
    git_dir: []const u8,
    repo_root: []const u8,
    collector: *GitFileCollector,
) void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const index_path = std.fmt.bufPrint(&path_buf, "{s}/index", .{git_dir}) catch return;

    var file = std.Io.Dir.openFileAbsolute(io, index_path, .{}) catch return;
    defer file.close(io);

    var stream_buf: [8192]u8 = undefined;
    var reader = file.reader(io, &stream_buf);

    var header_buf: [12]u8 = undefined;
    if (!readExact(&reader, &header_buf)) return;
    if (!std.mem.eql(u8, header_buf[0..4], "DIRC")) return;

    const version = std.mem.readInt(u32, header_buf[4..8][0..4], .big);
    if (version < 2 or version > 3) return;

    const entry_count = std.mem.readInt(u32, header_buf[8..12][0..4], .big);

    const root_dir = if (std.fs.path.isAbsolute(repo_root))
        std.Io.Dir.openDirAbsolute(io, repo_root, .{}) catch null
    else
        std.Io.Dir.cwd().openDir(io, repo_root, .{}) catch null;

    defer if (root_dir) |d| {
        var closed_dir = d;
        closed_dir.close(io);
    };

    var i: u32 = 0;
    while (i < entry_count) : (i += 1) {
        var entry_fixed: [62]u8 = undefined;
        if (!readExact(&reader, &entry_fixed)) break;

        const mtime_s = std.mem.readInt(u32, entry_fixed[8..12][0..4], .big);
        const mtime_ns = std.mem.readInt(u32, entry_fixed[12..16][0..4], .big);
        const mode = std.mem.readInt(u32, entry_fixed[24..28][0..4], .big);
        const file_size = std.mem.readInt(u32, entry_fixed[36..40][0..4], .big);
        const flags = std.mem.readInt(u16, entry_fixed[60..62][0..2], .big);

        const stage = (flags >> 12) & 0x03;

        const is_extended = (flags & (1 << 14)) != 0;
        var header_len: usize = 62;
        if (is_extended) {
            header_len = 64;
            var ext_extra: [2]u8 = undefined;
            if (!readExact(&reader, &ext_extra)) break;
        }

        var name_buf: [std.fs.max_path_bytes]u8 = undefined;
        const entry_name = readEntryName(&reader, &name_buf) orelse break;

        if (stage > 0) {
            collector.addConflicted(entry_name);
        }

        if (root_dir) |dir| {
            if (dir.statFile(io, entry_name, .{})) |st| {
                const on_disk_size = st.size;
                const on_disk_mtime_s: u32 = @intCast(@max(0, @divTrunc(st.mtime.toNanoseconds(), std.time.ns_per_s)));
                const on_disk_mtime_ns: u32 = @intCast(@max(0, @mod(st.mtime.toNanoseconds(), std.time.ns_per_s)));
                const is_regular_file = (mode & 0o170000) == 0o100000;

                const time_modified = if (mtime_s != 0 and on_disk_mtime_s != mtime_s)
                    true
                else if (mtime_s != 0 and on_disk_mtime_s == mtime_s and mtime_ns != 0 and on_disk_mtime_ns != 0 and on_disk_mtime_ns != mtime_ns)
                    true
                else
                    false;

                if (is_regular_file and (on_disk_size != file_size or time_modified)) {
                    collector.addModified(entry_name);
                }
            } else |err| switch (err) {
                error.FileNotFound => {
                    collector.addDeleted(entry_name);
                },
                else => {},
            }
        }

        if (!skipEntryPadding(&reader, header_len, entry_name.len)) break;
    }

    // Collect untracked files
    var gitignore = GitIgnore{};
    var gitignore_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var gi_content_buf: [16384]u8 = undefined;
    var gi_pos: usize = 0;

    if (std.fmt.bufPrint(&gitignore_path_buf, "{s}/.gitignore", .{repo_root}) catch null) |gi_path| {
        if (fs.readSmallFile(io, gi_path, gi_content_buf[gi_pos..])) |content| {
            gi_pos += content.len;
            if (gi_pos < gi_content_buf.len) {
                gi_content_buf[gi_pos] = '\n';
                gi_pos += 1;
            }
        }
    }
    if (std.fmt.bufPrint(&gitignore_path_buf, "{s}/info/exclude", .{git_dir}) catch null) |ex_path| {
        if (fs.readSmallFile(io, ex_path, gi_content_buf[gi_pos..])) |content| {
            gi_pos += content.len;
        }
    }
    if (gi_pos > 0) {
        gitignore = GitIgnore.parse(gi_content_buf[0..gi_pos]);
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

    while (q_head < q_tail and collector.untracked_count < GitFileCollector.MaxEntries and total_entries_scanned < 2000) {
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

        var dir_gi = GitIgnore{};
        var dir_gi_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        var dir_gi_content_buf: [8192]u8 = undefined;
        if (cur_rel.len > 0) {
            if (std.fmt.bufPrint(&dir_gi_path_buf, "{s}/.gitignore", .{full_dir_path}) catch null) |sub_gi_path| {
                if (fs.readSmallFile(io, sub_gi_path, &dir_gi_content_buf)) |content| {
                    dir_gi = GitIgnore.parse(content);
                }
            }
        }

        var it = d_handle.iterate();
        while (it.next(io) catch null) |entry| {
            total_entries_scanned += 1;
            if (total_entries_scanned > 2000) break;

            if (cur_rel.len == 0 and (std.mem.eql(u8, entry.name, ".git") or std.mem.eql(u8, entry.name, ".gitignore"))) continue;
            if (std.mem.eql(u8, entry.name, ".git") or std.mem.eql(u8, entry.name, ".gitignore")) continue;

            var rel_entry_buf: [std.fs.max_path_bytes]u8 = undefined;
            const rel_entry = if (cur_rel.len == 0)
                entry.name
            else
                std.fmt.bufPrint(&rel_entry_buf, "{s}/{s}", .{ cur_rel, entry.name }) catch continue;

            const is_directory = (entry.kind == .directory);
            if (gitignore.isIgnored(rel_entry, is_directory) or (dir_gi.content.len > 0 and dir_gi.isIgnored(entry.name, is_directory))) continue;

            if (is_directory) {
                if (q_tail < MaxQueue) {
                    @memcpy(queue_buf[q_tail][0..rel_entry.len], rel_entry);
                    queue_len[q_tail] = rel_entry.len;
                    q_tail += 1;
                }
            } else {
                const in_idx = if (idx_scanner) |*s| s.contains(rel_entry, false) else false;
                if (!in_idx) {
                    collector.addUntracked(rel_entry);
                }
            }
        }
    }
}
