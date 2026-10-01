const std = @import("std");

pub const cli = @import("cli/root.zig");

pub fn main(init: std.process.Init) !void {
    try cli.run(init);
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("tests/harness.zig");
}
