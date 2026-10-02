const std = @import("std");
const fs = @import("../fs.zig");
const testing = std.testing;

pub const IndexScanResult = struct {
    modified: bool = false,
    deleted: bool = false,
    conflicted: bool = false,
    staged: bool = false,
    untracked: bool = false,
    has_entries: bool = false,
    entry_count: u32 = 0,
};

pub const TrackedProbe = struct {
    name_buf: [128]u8 = undefined,
    len: usize = 0,
    is_dir: bool = false,
    tracked: bool = false,
};

/// Helper to read an exact slice of bytes from a streaming reader.
fn readExact(reader: anytype, dest: []u8) bool {
    var total: usize = 0;
    while (total < dest.len) {
        const n = reader.interface.readSliceShort(dest[total..]) catch return false;
        if (n == 0) return false;
        total += n;
    }
    return true;
}

/// Helper to read a single byte from a streaming reader.
fn readByte(reader: anytype) ?u8 {
    var b: [1]u8 = undefined;
    const n = reader.interface.readSliceShort(&b) catch return null;
    if (n == 0) return null;
    return b[0];
}

/// Reads a null-terminated file path from the index stream into a stack buffer.
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

/// Skips the 8-byte alignment padding at the end of each index entry.
///
/// Git Index Format: Each entry is padded with 1-8 NUL bytes to align the
/// entire entry (header + name + NUL + padding) to an 8-byte offset boundary.
/// Formula: aligned_len = (raw_len + 7) & ~7
fn skipEntryPadding(reader: anytype, header_len: usize, name_len: usize) bool {
    const raw_len = header_len + name_len + 1; // header + name + 1 NUL terminator
    const aligned_len = (raw_len + 7) & ~@as(usize, 7); // Round up to next multiple of 8
    const pad_needed = aligned_len - raw_len;
    if (pad_needed > 0) {
        var pad_buf: [8]u8 = undefined;
        return readExact(reader, pad_buf[0..pad_needed]);
    }
    return true;
}

pub const GitIndexScanner = struct {
    file: std.Io.File,
    stream_buf: [4096]u8 = undefined,
    entry_count: u32 = 0,
    version: u32 = 2,
    io: std.Io,

    pub fn open(io: std.Io, git_dir: []const u8) ?GitIndexScanner {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const index_path = std.fmt.bufPrint(&path_buf, "{s}/index", .{git_dir}) catch return null;
        const file = std.Io.Dir.openFileAbsolute(io, index_path, .{}) catch return null;
        var self = GitIndexScanner{ .file = file, .io = io };
        var reader = self.file.reader(io, &self.stream_buf);
        var header_buf: [12]u8 = undefined;
        if (!readExact(&reader, &header_buf)) {
            self.file.close(io);
            return null;
        }
        if (!std.mem.eql(u8, header_buf[0..4], "DIRC")) {
            self.file.close(io);
            return null;
        }
        self.version = std.mem.readInt(u32, header_buf[4..8][0..4], .big);
        self.entry_count = std.mem.readInt(u32, header_buf[8..12][0..4], .big);
        return self;
    }

    pub fn close(self: *GitIndexScanner) void {
        self.file.close(self.io);
    }

    pub fn contains(self: *GitIndexScanner, target_path: []const u8, is_dir: bool) bool {
        var reader = self.file.reader(self.io, &self.stream_buf);
        reader.seekTo(12) catch return false;
        var i: u32 = 0;
        while (i < self.entry_count) : (i += 1) {
            var entry_fixed: [62]u8 = undefined;
            if (!readExact(&reader, &entry_fixed)) break;
            const flags = std.mem.readInt(u16, entry_fixed[60..62][0..2], .big);
            const is_extended = (flags & (1 << 14)) != 0;
            var header_len: usize = 62;
            if (is_extended) {
                header_len = 64;
                var ext_extra: [2]u8 = undefined;
                if (!readExact(&reader, &ext_extra)) break;
            }

            var name_buf: [std.fs.max_path_bytes]u8 = undefined;
            const entry_name = readEntryName(&reader, &name_buf) orelse break;

            if (is_dir) {
                if (std.mem.startsWith(u8, entry_name, target_path)) {
                    if (entry_name.len == target_path.len or entry_name[target_path.len] == '/') {
                        return true;
                    }
                }
            } else {
                if (std.mem.eql(u8, entry_name, target_path)) {
                    return true;
                }
            }

            if (!is_dir and std.mem.order(u8, entry_name, target_path) == .gt) {
                return false;
            }

            if (!skipEntryPadding(&reader, header_len, entry_name.len)) break;
        }
        return false;
    }
};

/// Checks if a file or directory prefix exists in binary .git/index.
/// Uses the fact that Git index entries are sorted lexicographically for early exit.
pub fn isPathInIndex(
    io: std.Io,
    git_dir: []const u8,
    target_path: []const u8,
    is_dir: bool,
) bool {
    var scanner = GitIndexScanner.open(io, git_dir) orelse return false;
    defer scanner.close();
    return scanner.contains(target_path, is_dir);
}

/// Scans the binary extension blocks at the tail of .git/index (after all file entries).
///
/// Looks specifically for the 'TREE' (cache-tree) extension:
/// If any tree entry has count == -1, it means staging changes have invalidated the tree (staged = true).
fn scanExtensionBlocks(reader: anytype, result: *IndexScanResult) void {
    while (true) {
        // Extension Header: 4-byte signature + 4-byte big-endian size
        var ext_hdr: [8]u8 = undefined;
        if (!readExact(reader, &ext_hdr)) break;

        const ext_sig = ext_hdr[0..4];
        const ext_size = std.mem.readInt(u32, ext_hdr[4..8][0..4], .big);

        if (std.mem.eql(u8, ext_sig, "TREE")) {
            var remaining: usize = ext_size;
            var tree_buf: [1024]u8 = undefined;
            while (remaining > 0) {
                const to_read = @min(remaining, tree_buf.len);
                if (!readExact(reader, tree_buf[0..to_read])) break;
                remaining -= to_read;
                // An entry count of -1 in the cache-tree denotes invalidated tree => staged changes present
                if (std.mem.indexOf(u8, tree_buf[0..to_read], "-1") != null) {
                    result.staged = true;
                }
            }
        } else {
            // Discard other extensions (REUC, UNTR, FSMN, etc.)
            var remaining: usize = ext_size;
            var discard_buf: [1024]u8 = undefined;
            while (remaining > 0) {
                const to_read = @min(remaining, discard_buf.len);
                if (!readExact(reader, discard_buf[0..to_read])) break;
                remaining -= to_read;
            }
        }
    }
}

/// Streams binary .git/index file, detects modified, deleted, conflicted, and staged files.
/// Operates in O(N) time with O(1) stack memory (zero heap allocations).
pub fn scanGitIndex(
    io: std.Io,
    git_dir: []const u8,
    repo_root: []const u8,
) IndexScanResult {
    var result = IndexScanResult{};

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const index_path = std.fmt.bufPrint(&path_buf, "{s}/index", .{git_dir}) catch return result;

    var file = std.Io.Dir.openFileAbsolute(io, index_path, .{}) catch return result;
    defer file.close(io);

    var stream_buf: [8192]u8 = undefined;
    var reader = file.reader(io, &stream_buf);

    // Git Index Header (12 bytes)
    var header_buf: [12]u8 = undefined;
    if (!readExact(&reader, &header_buf)) return result;

    if (!std.mem.eql(u8, header_buf[0..4], "DIRC")) return result;

    const version = std.mem.readInt(u32, header_buf[4..8][0..4], .big);
    if (version < 2 or version > 3) return result;

    const entry_count = std.mem.readInt(u32, header_buf[8..12][0..4], .big);
    result.entry_count = entry_count;
    if (entry_count > 0) {
        result.has_entries = true;
    }

    const root_dir = if (std.fs.path.isAbsolute(repo_root))
        std.Io.Dir.openDirAbsolute(io, repo_root, .{}) catch null
    else
        std.Io.Dir.cwd().openDir(io, repo_root, .{}) catch null;

    var i: u32 = 0;
    while (i < entry_count) : (i += 1) {
        // Binary entry fixed header:
        // 0..4: ctime seconds, 4..8: ctime nanoseconds
        // 8..12: mtime seconds, 12..16: mtime nanoseconds
        // 16..20: dev, 20..24: ino, 24..28: mode, 28..32: uid, 32..36: gid
        // 36..40: file size in bytes
        // 40..60: 20-byte SHA-1 object ID
        // 60..62: 16-bit flags (stage in bits 12-13, extended flag in bit 14)
        var entry_fixed: [62]u8 = undefined;
        if (!readExact(&reader, &entry_fixed)) break;

        const mtime_s = std.mem.readInt(u32, entry_fixed[8..12][0..4], .big);
        const mtime_ns = std.mem.readInt(u32, entry_fixed[12..16][0..4], .big);
        const file_size = std.mem.readInt(u32, entry_fixed[36..40][0..4], .big);
        const flags = std.mem.readInt(u16, entry_fixed[60..62][0..2], .big);

        // Stage > 0 (bits 12..13) indicates unmerged merge conflict entry
        const stage = (flags >> 12) & 0x03;
        if (stage > 0) {
            result.conflicted = true;
        }

        const is_extended = (flags & (1 << 14)) != 0;
        var header_len: usize = 62;
        if (is_extended) {
            header_len = 64;
            var ext_extra: [2]u8 = undefined;
            if (!readExact(&reader, &ext_extra)) break;
        }

        var name_buf: [std.fs.max_path_bytes]u8 = undefined;
        const entry_name = readEntryName(&reader, &name_buf) orelse break;

        // Stat file in working tree to detect unstaged modifications / deletions
        if (root_dir) |dir| {
            if (dir.statFile(io, entry_name, .{})) |st| {
                const on_disk_size = st.size;
                const on_disk_mtime_s: u32 = @intCast(@max(0, @divTrunc(st.mtime.toNanoseconds(), std.time.ns_per_s)));
                const on_disk_mtime_ns: u32 = @intCast(@max(0, @mod(st.mtime.toNanoseconds(), std.time.ns_per_s)));

                if (on_disk_size != file_size or
                    (mtime_s != 0 and on_disk_mtime_s != mtime_s) or
                    (mtime_ns != 0 and on_disk_mtime_ns != mtime_ns))
                {
                    result.modified = true;
                }
            } else |err| switch (err) {
                error.FileNotFound => {
                    result.deleted = true;
                },
                else => {},
            }
        }

        if (!skipEntryPadding(&reader, header_len, entry_name.len)) break;
    }

    if (root_dir) |d| {
        var closed_dir = d;
        closed_dir.close(io);
    }

    // Scan extension blocks at the end of the index for 'TREE' invalidation
    scanExtensionBlocks(&reader, &result);

    return result;
}

test "unit: scanGitIndex parses DIRC header correctly" {
    var dirc_data: [12]u8 = undefined;
    @memcpy(dirc_data[0..4], "DIRC");
    std.mem.writeInt(u32, dirc_data[4..8][0..4], 2, .big); // version 2
    std.mem.writeInt(u32, dirc_data[8..12][0..4], 0, .big); // 0 entries

    try testing.expectEqualStrings("DIRC", dirc_data[0..4]);
    try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, dirc_data[4..8][0..4], .big));
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, dirc_data[8..12][0..4], .big));
}

const Harness = @import("../../tests/harness.zig").Harness;

test "unit: scanGitIndex detects deleted and modified files" {
    var h = try Harness.create(testing.allocator);
    defer h.destroy();

    try h.setupGit();
    try h.writeFile("f1.txt", "content1");
    try h.writeFile("f2.txt", "content2");
    try h.git(&.{ "add", "." });
    try h.git(&.{ "commit", "-m", "init" });

    // 1. Initial state: clean
    var git_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const git_dir = try std.fmt.bufPrint(&git_dir_buf, "{s}/.git", .{h.tmp_dir});
    var res = scanGitIndex(testing.io, git_dir, h.tmp_dir);
    try testing.expect(!res.deleted);
    try testing.expect(!res.modified);

    // 2. Delete f1.txt from disk (unstaged deletion)
    try h.deleteFile("f1.txt");
    res = scanGitIndex(testing.io, git_dir, h.tmp_dir);
    try testing.expect(res.deleted);

    // 3. Modify f2.txt on disk (unstaged modification)
    try h.writeFile("f2.txt", "content2_modified");
    res = scanGitIndex(testing.io, git_dir, h.tmp_dir);
    try testing.expect(res.modified);
}
