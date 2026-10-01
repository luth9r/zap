const std = @import("std");
const testing = std.testing;

/// A lightweight, zero-heap-allocation streaming writer over a preallocated byte buffer.
pub const BufferWriter = struct {
    buf: []u8,
    pos: *usize,

    pub fn init(buf: []u8, pos: *usize) BufferWriter {
        return .{ .buf = buf, .pos = pos };
    }

    pub fn writeByte(self: BufferWriter, byte: u8) !void {
        if (self.pos.* < self.buf.len) {
            self.buf[self.pos.*] = byte;
            self.pos.* += 1;
        }
    }

    pub fn writeAll(self: BufferWriter, bytes: []const u8) !void {
        const avail = self.buf.len - self.pos.*;
        const copy_len = @min(bytes.len, avail);
        @memcpy(self.buf[self.pos.* .. self.pos.* + copy_len], bytes[0..copy_len]);
        self.pos.* += copy_len;
    }

    pub fn print(self: BufferWriter, comptime fmt: []const u8, args: anytype) !void {
        if (self.pos.* >= self.buf.len) return;
        const slice = self.buf[self.pos.*..];
        const res = std.fmt.bufPrint(slice, fmt, args) catch {
            self.pos.* = self.buf.len;
            return;
        };
        self.pos.* += res.len;
    }

    pub fn written(self: BufferWriter) []const u8 {
        return self.buf[0..self.pos.*];
    }
};

test "unit: BufferWriter writes bytes and slices up to capacity" {
    var memory: [16]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&memory, &pos);

    try writer.writeByte('H');
    try writer.writeAll("ello, World!");

    try testing.expectEqualStrings("Hello, World!", writer.written());
    try testing.expectEqual(@as(usize, 13), pos);

    // Overflow protection: writing past capacity truncates safely without crashing
    try writer.writeAll("EXTRA BYTES THAT EXCEED");
    try testing.expectEqual(@as(usize, 16), pos);
    try testing.expectEqualStrings("Hello, World!EXT", memory[0..16]);
}

test "unit: BufferWriter multi-byte UTF-8 emoji and symbols" {
    var memory: [64]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&memory, &pos);

    try writer.writeAll("⚡ 🦀 📁 🚀");
    try testing.expectEqualStrings("⚡ 🦀 📁 🚀", writer.written());
    try testing.expect(std.unicode.utf8ValidateSlice(writer.written()));
}

test "unit: BufferWriter print with formatting and safe truncation" {
    var memory: [12]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&memory, &pos);

    try writer.print("{s} = {d}", .{ "count", 42 });
    try testing.expectEqualStrings("count = 42", writer.written());

    // Printing past limit safely caps at memory.len
    try writer.print(" - and more data {d}", .{999});
    try testing.expectEqual(@as(usize, 12), pos);
    try testing.expectEqual(@as(usize, 12), writer.written().len);
}

