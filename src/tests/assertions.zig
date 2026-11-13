const std = @import("std");
const Shell = @import("../init/root.zig").Shell;
const Fixture = @import("fixture.zig").Fixture;

pub fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print(
            \\
            \\[ASSERT FAIL] Expected output to contain: "{s}"
            \\[ASSERT FAIL] Actual output ({d} bytes):
            \\──────────────────
            \\{s}
            \\──────────────────
            \\
        , .{ needle, haystack.len, haystack });
        return error.TestExpectedContains;
    }
}

pub fn expectNotContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) != null) {
        std.debug.print(
            \\
            \\[ASSERT FAIL] Expected output to NOT contain: "{s}"
            \\[ASSERT FAIL] Actual output: {s}
            \\
        , .{ needle, haystack });
        return error.TestExpectedNotContains;
    }
}

pub fn expectNotEmpty(output: []const u8) !void {
    if (output.len == 0) {
        std.debug.print("\n[ASSERT FAIL] Expected non-empty output\n", .{});
        return error.TestExpectedNotEmpty;
    }
}

pub fn expectAnsi(output: []const u8, shell: Shell) !void {
    Fixture.assertValidShellAnsi(output, shell) catch |err| {
        std.debug.print(
            \\
            \\[ASSERT FAIL] Invalid ANSI escapes for shell {s}: {any}
            \\[ASSERT FAIL] Output: {s}
            \\
        , .{ @tagName(shell), err, output });
        return err;
    };
}

pub fn stripAnsi(alloc: std.mem.Allocator, text: []const u8) ![]const u8 {
    return Fixture.stripAnsi(alloc, text);
}

pub fn expectVisibleText(output: []const u8, expected: []const u8) !void {
    var stack_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&stack_buf);
    const stripped = Fixture.stripAnsi(fba.allocator(), output) catch output;
    try expectContains(stripped, expected);
}
