const std = @import("std");
pub const Shell = @import("../init/root.zig").Shell;

/// Execution context required to render prompt modules.
pub const PromptContext = struct {
    cwd: []const u8,
    home: []const u8,
    status_code: u8 = 0,
    cmd_duration: u64 = 0,
    shell: Shell = .generic,
    io: ?std.Io = null,
    git_dir: ?[]const u8 = null,
};

pub const DebugContext = struct {
    prompt: PromptContext,
    json: bool = false,
    verbose: bool = false,
};

pub fn resolveHomePath(init: std.process.Init) []const u8 {
    return init.environ_map.get("HOME") orelse init.environ_map.get("USERPROFILE") orelse ".";
}

pub fn resolveCwdPath(init: std.process.Init, buf: *[std.fs.max_path_bytes]u8) []const u8 {
    if (init.environ_map.get("PWD")) |pwd| {
        return pwd;
    }

    const cwd: std.Io.Dir = .cwd();
    const pwd_file = cwd.openFile(init.io, ".", .{}) catch return ".";
    defer pwd_file.close(init.io);

    const len = pwd_file.realPath(init.io, buf) catch return ".";
    return buf[0..len];
}
