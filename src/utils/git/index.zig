const std = @import("std");
const ignore = @import("ignore.zig");

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

/// Checks if a file path is tracked in the .git/index file.
pub fn isPathTrackedInIndex(io: std.Io, git_dir: []const u8, name: []const u8) bool {
    var index_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const index_path = std.fmt.bufPrint(&index_path_buf, "{s}/index", .{git_dir}) catch return true;

    const file = std.Io.Dir.openFileAbsolute(io, index_path, .{}) catch return true;
    defer file.close(io);

    var stream_buf: [2048]u8 = undefined;
    var file_reader = file.reader(io, &stream_buf);

    var header: [12]u8 = undefined;
    const h_bytes = file_reader.interface.readSliceShort(&header) catch return true;
    if (h_bytes < 12) return true;
    if (!std.mem.eql(u8, header[0..4], "DIRC")) return true;

    const num_entries = std.mem.readInt(u32, header[8..12], .big);
    var entry_idx: usize = 0;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;

    while (entry_idx < num_entries) : (entry_idx += 1) {
        var entry_hdr: [62]u8 = undefined;
        const hdr_read = file_reader.interface.readSliceShort(&entry_hdr) catch break;
        if (hdr_read < 62) break;

        const flags = std.mem.readInt(u16, entry_hdr[60..62], .big);
        var extra_flag_len: usize = 0;
        if ((flags & 0x4000) != 0) {
            var extra: [2]u8 = undefined;
            _ = file_reader.interface.readSliceShort(&extra) catch break;
            extra_flag_len = 2;
        }

        var path_len: usize = 0;
        while (path_len < path_buf.len) {
            var c_buf: [1]u8 = undefined;
            const cr = file_reader.interface.readSliceShort(&c_buf) catch break;
            if (cr == 0) break;
            if (c_buf[0] == 0) break;
            path_buf[path_len] = c_buf[0];
            path_len += 1;
        }

        const entry_bytes = 62 + extra_flag_len + path_len + 1;
        const pad = if (entry_bytes % 8 == 0) 0 else (8 - (entry_bytes % 8));
        var pad_buf: [8]u8 = undefined;
        if (pad > 0) {
            _ = file_reader.interface.readSliceShort(pad_buf[0..pad]) catch break;
        }

        const rel_path = path_buf[0..path_len];
        if (std.mem.startsWith(u8, rel_path, name)) {
            if (rel_path.len == name.len or rel_path[name.len] == '/') {
                return true;
            }
        }
    }
    return false;
}

/// Parses .git/index and compares tracked files against filesystem without child processes.
pub fn parseIndexAndWorktree(
    io: std.Io,
    work_dir: []const u8,
    git_dir: []const u8,
    info: *GitStatusInfo,
) void {
    var index_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const index_path = std.fmt.bufPrint(&index_path_buf, "{s}/index", .{git_dir}) catch return;

    const file = std.Io.Dir.openFileAbsolute(io, index_path, .{}) catch return;
    defer file.close(io);

    var stream_buf: [4096]u8 = undefined;
    var file_reader = file.reader(io, &stream_buf);

    var header: [12]u8 = undefined;
    const h_bytes = file_reader.interface.readSliceShort(&header) catch return;
    if (h_bytes < 12) return;

    if (!std.mem.eql(u8, header[0..4], "DIRC")) return;
    const version = std.mem.readInt(u32, header[4..8], .big);
    const num_entries = std.mem.readInt(u32, header[8..12], .big);

    if (version != 2 and version != 3 and version != 4) return;

    var entry_idx: usize = 0;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var full_path_buf: [std.fs.max_path_bytes]u8 = undefined;

    while (entry_idx < num_entries) : (entry_idx += 1) {
        if (version == 2 or version == 3) {
            var entry_hdr: [62]u8 = undefined;
            const hdr_read = file_reader.interface.readSliceShort(&entry_hdr) catch break;
            if (hdr_read < 62) break;

            const mtime_sec = std.mem.readInt(u32, entry_hdr[8..12], .big);
            const file_size = std.mem.readInt(u32, entry_hdr[36..40], .big);
            const flags = std.mem.readInt(u16, entry_hdr[60..62], .big);

            const stage = (flags >> 12) & 0x03;
            if (stage > 0) {
                info.conflicted = true;
            }

            var extra_flag_len: usize = 0;
            if ((flags & 0x4000) != 0) {
                var extra: [2]u8 = undefined;
                _ = file_reader.interface.readSliceShort(&extra) catch break;
                extra_flag_len = 2;
            }

            var path_len: usize = 0;
            while (path_len < path_buf.len) {
                var c_buf: [1]u8 = undefined;
                const cr = file_reader.interface.readSliceShort(&c_buf) catch break;
                if (cr == 0) break;
                if (c_buf[0] == 0) break;
                path_buf[path_len] = c_buf[0];
                path_len += 1;
            }

            const entry_bytes = 62 + extra_flag_len + path_len + 1;
            const pad = if (entry_bytes % 8 == 0) 0 else (8 - (entry_bytes % 8));
            var pad_buf: [8]u8 = undefined;
            if (pad > 0) {
                _ = file_reader.interface.readSliceShort(pad_buf[0..pad]) catch break;
            }

            const rel_path = path_buf[0..path_len];
            const full_path = std.fmt.bufPrint(&full_path_buf, "{s}/{s}", .{ work_dir, rel_path }) catch continue;

            if (std.Io.Dir.openFileAbsolute(io, full_path, .{})) |item_file| {
                defer item_file.close(io);
                if (item_file.stat(io)) |stat| {
                    const disk_size: u64 = stat.size;
                    const disk_mtime_sec = @as(u32, @truncate(@as(u64, @intCast(@divTrunc(stat.mtime.nanoseconds, std.time.ns_per_s)))));
                    if (disk_size != @as(u64, file_size) or disk_mtime_sec != mtime_sec) {
                        info.modified = true;
                    }
                } else |_| {
                    info.modified = true;
                }
            } else |err| {
                if (err == error.FileNotFound) {
                    info.deleted = true;
                }
            }
        } else {
            break;
        }
    }
}

/// Checks if there are any untracked files in the repository without invoking child processes.
pub fn checkUntracked(io: std.Io, work_dir: []const u8, git_dir: []const u8) bool {
    return checkUntrackedDir(io, work_dir, git_dir, "");
}

fn checkUntrackedDir(io: std.Io, work_dir: []const u8, git_dir: []const u8, rel_prefix: []const u8) bool {
    var full_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const current_dir_path = if (rel_prefix.len == 0)
        work_dir
    else
        std.fmt.bufPrint(&full_dir_buf, "{s}/{s}", .{ work_dir, rel_prefix }) catch return false;

    const dir = std.Io.Dir.openDirAbsolute(io, current_dir_path, .{ .iterate = true }) catch return false;
    var d = dir;
    defer d.close(io);

    var it = d.iterate();
    var child_rel_buf: [std.fs.max_path_bytes]u8 = undefined;

    while (it.next(io) catch null) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') continue;

        const child_rel = if (rel_prefix.len == 0)
            entry.name
        else
            std.fmt.bufPrint(&child_rel_buf, "{s}/{s}", .{ rel_prefix, entry.name }) catch continue;

        // Check if ignored by .gitignore or .git/info/exclude
        if (ignore.isIgnored(io, work_dir, git_dir, entry.name) or ignore.isIgnored(io, work_dir, git_dir, child_rel)) continue;

        switch (entry.kind) {
            .directory => {
                if (checkUntrackedDir(io, work_dir, git_dir, child_rel)) {
                    return true;
                }
            },
            .file, .sym_link => {
                if (!isPathTrackedInIndex(io, git_dir, child_rel)) {
                    return true;
                }
            },
            else => {},
        }
    }
    return false;
}
