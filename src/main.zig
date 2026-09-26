const std = @import("std");
const Config = @import("config.zig").Config;
const path_utils = @import("path_utils.zig");
const prompt_char = @import("prompt_char.zig");
const toml_parser = @import("toml_parser.zig");

pub fn main(init: std.process.Init) !void {
    // Initialize the standard library's allocator and set up an arena for memory management.
    const allocator = init.arena.allocator();
    var config = Config{};
    toml_parser.loadConfigFile(init.io, allocator, init.environ_map, &config);

    const status_code = try parseStatusCode(init, allocator);

    const home_path = resolveHomePath(init);
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_path = resolveCwdPath(init, &cwd_buf);

    const formatted_path = try path_utils.formatPath(allocator, cwd_path, home_path, config.path);
    const prompt_result = prompt_char.renderPromptChar(status_code, config.prompt);

    const prefix = if (config.add_newline) "\n" else "";
    const reset = "\x1b[0m";

    // Format the prompt string with the appropriate colors and symbols.
    // {s} -> formatted_path (path)
    // {s} -> config.prompt.color (color for the prompt symbol)
    // {s} -> config.prompt.symbol (prompt symbol)
    // {s} -> reset (reset color code)
    const prompt = try std.fmt.allocPrint(
        allocator,
        "{s}{s} {s}{s}{s} ",
        .{
            prefix,
            formatted_path,
            prompt_result.color,
            prompt_result.symbol,
            reset,
        },
    );

    try std.Io.File.stdout().writeStreamingAll(init.io, prompt);
}

fn parseStatusCode(init: std.process.Init, allocator: std.mem.Allocator) !u8 {
    var args = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();

    _ = args.next(); // Skip file name

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
