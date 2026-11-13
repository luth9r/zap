const std = @import("std");
const builtin = @import("builtin");

pub const is_windows = builtin.os.tag == .windows;
pub const sep: []const u8 = std.fs.path.sep_str;
pub const sep_char: u8 = std.fs.path.sep;
pub const fs_root: []const u8 = if (is_windows) "C:\\" else "/";
pub const exe_ext: []const u8 = if (is_windows) ".exe" else "";

pub const EnvEntry = struct {
    key: []const u8,
    value: ?[]const u8,
};

pub fn isSep(c: u8) bool {
    return c == '/' or c == '\\';
}

pub fn pathCharsEqual(a: u8, b: u8) bool {
    if (a == b) return true;
    if (isSep(a) and isSep(b)) return true;
    if (is_windows) {
        return std.ascii.toLower(a) == std.ascii.toLower(b);
    }
    return false;
}

pub fn pathStartsWith(path: []const u8, prefix: []const u8) bool {
    if (path.len < prefix.len) return false;
    for (prefix, 0..) |p, i| {
        if (!pathCharsEqual(path[i], p)) return false;
    }
    return true;
}

pub fn pathEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    return pathStartsWith(a, b);
}

pub fn joinPath(buf: []u8, base: []const u8, sub: []const u8) ?[]const u8 {
    const trimmed_base = if (base.len > 1 and isSep(base[base.len - 1]))
        base[0 .. base.len - 1]
    else
        base;
    const trimmed_sub = if (sub.len > 0 and isSep(sub[0]))
        sub[1..]
    else
        sub;

    if (trimmed_base.len > 0 and isSep(trimmed_base[trimmed_base.len - 1])) {
        return std.fmt.bufPrint(buf, "{s}{s}", .{ trimmed_base, trimmed_sub }) catch null;
    }
    return std.fmt.bufPrint(buf, "{s}{s}{s}", .{ trimmed_base, sep, trimmed_sub }) catch null;
}

/// Enables UTF-8 output and VT100 escapes on Windows consoles (no-op when piped).
pub fn enableConsole() void {
    if (!is_windows) return;
    const kernel32 = struct {
        const WINAPI: std.builtin.CallingConvention = if (builtin.cpu.arch == .x86) .stdcall else .c;
        extern "kernel32" fn SetConsoleOutputCP(wCodePageID: u32) callconv(WINAPI) c_int;
        extern "kernel32" fn GetStdHandle(nStdHandle: u32) callconv(WINAPI) ?*anyopaque;
        extern "kernel32" fn GetConsoleMode(hConsoleHandle: *anyopaque, lpMode: *u32) callconv(WINAPI) c_int;
        extern "kernel32" fn SetConsoleMode(hConsoleHandle: *anyopaque, dwMode: u32) callconv(WINAPI) c_int;
    };

    const CP_UTF8: u32 = 65001;
    const STD_OUTPUT_HANDLE: u32 = @bitCast(@as(i32, -11));
    const ENABLE_VIRTUAL_TERMINAL_PROCESSING: u32 = 0x0004;
    const invalid_handle: *anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));

    _ = kernel32.SetConsoleOutputCP(CP_UTF8);

    if (kernel32.GetStdHandle(STD_OUTPUT_HANDLE)) |handle| {
        if (handle != invalid_handle) {
            var mode: u32 = 0;
            if (kernel32.GetConsoleMode(handle, &mode) != 0) {
                _ = kernel32.SetConsoleMode(handle, mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING);
            }
        }
    }
}

pub fn getEnvWindows(name: []const u8, out_utf8: []u8) ?[]const u8 {
    if (!is_windows) return null;
    const kernel32 = struct {
        const WINAPI: std.builtin.CallingConvention = if (builtin.cpu.arch == .x86) .stdcall else .c;
        extern "kernel32" fn GetEnvironmentVariableW(
            lpName: [*:0]const u16,
            lpBuffer: [*]u16,
            nSize: u32,
        ) callconv(WINAPI) u32;
    };

    var name_w: [64:0]u16 = undefined;
    const name_len = std.unicode.utf8ToUtf16Le(&name_w, name) catch return null;
    name_w[name_len] = 0;

    var buf_w: [std.fs.max_path_bytes]u16 = undefined;
    const len = kernel32.GetEnvironmentVariableW(&name_w, &buf_w, buf_w.len);
    if (len == 0 or len >= buf_w.len) return null;

    const utf8_len = std.unicode.utf16LeToUtf8(out_utf8, buf_w[0..len]) catch return null;
    return out_utf8[0..utf8_len];
}

pub fn setEnvWindows(name: []const u8, value: ?[]const u8) void {
    if (!is_windows) return;
    const kernel32 = struct {
        const WINAPI: std.builtin.CallingConvention = if (builtin.cpu.arch == .x86) .stdcall else .c;
        extern "kernel32" fn SetEnvironmentVariableW(
            lpName: [*:0]const u16,
            lpValue: ?[*:0]const u16,
        ) callconv(WINAPI) c_int;
    };

    var name_w: [64:0]u16 = undefined;
    const name_len = std.unicode.utf8ToUtf16Le(&name_w, name) catch return;
    name_w[name_len] = 0;

    if (value) |v| {
        var val_w: [std.fs.max_path_bytes:0]u16 = undefined;
        const val_len = std.unicode.utf8ToUtf16Le(&val_w, v) catch return;
        val_w[val_len] = 0;
        _ = kernel32.SetEnvironmentVariableW(&name_w, &val_w);
    } else {
        _ = kernel32.SetEnvironmentVariableW(&name_w, null);
    }
}

pub fn testTempSubdir(buf: *[std.fs.max_path_bytes]u8, name: []const u8) ![]const u8 {
    if (is_windows) {
        var env_buf: [std.fs.max_path_bytes]u8 = undefined;
        const temp_base = getEnvWindows("TEMP", &env_buf) orelse
            getEnvWindows("TMP", &env_buf) orelse
            getEnvWindows("USERPROFILE", &env_buf) orelse
            "C:\\Temp";
        return std.fmt.bufPrint(buf, "{s}\\{s}", .{ temp_base, name });
    }
    return std.fmt.bufPrint(buf, "/tmp/{s}", .{name});
}

pub fn spawnWithEnv(
    io: std.Io,
    alloc: std.mem.Allocator,
    cwd: ?[]const u8,
    env_vars: []const EnvEntry,
    argv: []const []const u8,
) !std.process.Child {
    const cwd_opt: @FieldType(std.process.SpawnOptions, "cwd") = if (cwd) |c| .{ .path = c } else .inherit;

    if (is_windows) {
        for (env_vars) |entry| {
            setEnvWindows(entry.key, entry.value);
        }
        return std.process.spawn(io, .{
            .argv = argv,
            .cwd = cwd_opt,
            .stdout = .pipe,
            .stderr = .pipe,
            .stdin = .ignore,
        });
    }

    var full_argv = try alloc.alloc([]const u8, 1 + env_vars.len + argv.len);
    full_argv[0] = "env";
    for (env_vars, 0..) |entry, i| {
        full_argv[1 + i] = if (entry.value) |v|
            try std.fmt.allocPrint(alloc, "{s}={s}", .{ entry.key, v })
        else
            try std.fmt.allocPrint(alloc, "{s}=", .{entry.key});
    }
    @memcpy(full_argv[1 + env_vars.len ..], argv);

    return std.process.spawn(io, .{
        .argv = full_argv,
        .cwd = cwd_opt,
        .stdout = .pipe,
        .stderr = .pipe,
        .stdin = .ignore,
    });
}

pub fn createSymlink(io: std.Io, target: []const u8, link_path: []const u8) bool {
    if (is_windows) return false;
    var child = std.process.spawn(io, .{
        .argv = &.{ "ln", "-s", target, link_path },
        .stdout = .ignore,
        .stderr = .ignore,
        .stdin = .ignore,
    }) catch return false;
    const term = child.wait(io) catch return false;
    return term == .exited and term.exited == 0;
}

pub fn setDirReadOnly(io: std.Io, dir_path: []const u8) bool {
    if (is_windows) return false;
    var child = std.process.spawn(io, .{
        .argv = &.{ "chmod", "555", dir_path },
        .stdout = .ignore,
        .stderr = .ignore,
        .stdin = .ignore,
    }) catch return false;
    const term = child.wait(io) catch return false;
    return term == .exited and term.exited == 0;
}

const testing = std.testing;

test "unit: platform.isSep recognizes both separators" {
    try testing.expect(isSep('/'));
    try testing.expect(isSep('\\'));
    try testing.expect(!isSep('a'));
}

test "unit: platform.pathStartsWith handles mixed separators" {
    try testing.expect(pathStartsWith("/home/user/zap", "/home/user"));
    try testing.expect(pathStartsWith("C:\\Users\\user\\zap", "C:/Users/user"));
    try testing.expect(!pathStartsWith("/home/other", "/home/user"));
}

test "unit: platform.joinPath avoids duplicate separators" {
    var buf: [256]u8 = undefined;
    const p1 = joinPath(&buf, "/home/user/", ".git").?;
    try testing.expectEqualStrings("/home/user" ++ sep ++ ".git", p1);

    const p2 = joinPath(&buf, "/", ".git").?;
    try testing.expectEqualStrings("/.git", p2);
}
