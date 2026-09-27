const std = @import("std");

/// Execution context required to render prompt modules.
pub const PromptContext = struct {
    cwd: []const u8,
    home: []const u8,
    status_code: u8 = 0,
    cmd_duration: u64 = 0,
    io: ?std.Io = null,
};
