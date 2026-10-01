const std = @import("std");
const build_options = @import("build_options");
const BufferWriter = @import("../../utils/buffer_writer.zig").BufferWriter;

pub fn executeVersion(io: std.Io) !void {
    var buf: [256]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);
    try writer.print("zap {s} (Zig 0.16+)\n", .{build_options.version});
    try std.Io.File.stdout().writeStreamingAll(io, buf[0..pos]);
}

const testing = std.testing;
const Harness = @import("../../tests/harness.zig").Harness;

test "integration: zap --version and -v" {
    var h = try Harness.create(testing.allocator);
    defer h.destroy();

    const out_long = try h.execZap(&.{"--version"});
    try Harness.expectContains(out_long, "zap 1.0.0");

    const out_short = try h.execZap(&.{"-v"});
    try Harness.expectContains(out_short, "zap 1.0.0");
}
