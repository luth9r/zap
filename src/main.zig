const std = @import("std");

pub const cli = @import("cli/root.zig");
pub const engine = @import("engine/prompt.zig");
pub const config = @import("config/config.zig");
pub const modules = @import("modules/registry.zig");
pub const utils = @import("utils/git_utils.zig");
pub const fs = @import("utils/fs.zig");

pub fn main(init: std.process.Init) !void {
    try cli.run(init);
}

test "unit: main refAllDecls" {
    std.testing.refAllDecls(@This());
    _ = @import("tests/harness.zig");
    _ = @import("tests/fixture.zig");
}
