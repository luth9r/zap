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
