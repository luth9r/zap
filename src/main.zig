const std = @import("std");

pub const config_mod = @import("config/config.zig");
pub const toml_parser = @import("config/toml_parser.zig");
pub const style = @import("engine/style.zig");
pub const formatter = @import("engine/formatter.zig");
pub const prompt = @import("engine/prompt.zig");
pub const directory = @import("modules/directory.zig");
pub const character = @import("modules/character.zig");
pub const buffer_writer = @import("utils/buffer_writer.zig");
pub const path_utils = @import("utils/path_utils.zig");
pub const color_utils = @import("utils/color_utils.zig");

const Config = config_mod.Config;
const BufferWriter = buffer_writer.BufferWriter;

pub fn main(init: std.process.Init) !void {
    var config = Config{};
    var config_file_buf: [64 * 1024]u8 = undefined;
    toml_parser.loadConfigFile(init.io, init.environ_map, &config, &config_file_buf);

    const status_code = try parseStatusCode(init, init.arena.allocator());

    const home_path = resolveHomePath(init);
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_path = resolveCwdPath(init, &cwd_buf);

    var prompt_buf: [4096]u8 = undefined;
    var pos: usize = 0;

    const writer = BufferWriter.init(&prompt_buf, &pos);

    // Render all prompt modules via the prompt orchestrator
    try prompt.render(writer, config, .{
        .cwd = cwd_path,
        .home = home_path,
        .status_code = status_code,
    });

    // Output the rendered prompt buffer in a single syscall
    try std.Io.File.stdout().writeStreamingAll(init.io, prompt_buf[0..pos]);
}

fn parseStatusCode(init: std.process.Init, allocator: std.mem.Allocator) !u8 {
    var args = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();

    _ = args.next(); // Skip executable name

    if (args.next()) |status_raw| {
        return std.fmt.parseInt(u8, status_raw, 10) catch 0;
    }
    return 0;
}

fn resolveHomePath(init: std.process.Init) []const u8 {
    return init.environ_map.get("HOME") orelse init.environ_map.get("USERPROFILE") orelse ".";
}

fn resolveCwdPath(init: std.process.Init, buf: *[std.fs.max_path_bytes]u8) []const u8 {
    if (init.environ_map.get("PWD")) |pwd| {
        return pwd;
    }

    const cwd: std.Io.Dir = .cwd();
    const pwd_file = cwd.openFile(init.io, ".", .{}) catch return ".";
    defer pwd_file.close(init.io);

    const len = pwd_file.realPath(init.io, buf) catch return ".";
    return buf[0..len];
}

test {
    std.testing.refAllDecls(@This());
}
