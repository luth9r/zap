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

    var status_code: u8 = 0;

    var args = init.minimal.args.iterate();

    _ = args.next();

    if (args.next()) |status_raw| {
        status_code = std.fmt.parseInt(u8, status_raw, 10) catch 0;
    }

    // Get the current working directory and the HOME environment variable.
    const cwd_path = init.environ_map.get("PWD") orelse ".";
    const home_path = init.environ_map.get("HOME") orelse ".";

    const formatted_path = try path_utils.formatPath(allocator, cwd_path, home_path, config.path);
    const prompt_result = prompt_char.renderPromptChar(status_code, config.prompt);

    const reset = "\x1b[0m";

    // Format the prompt string with the appropriate colors and symbols.
    // {s} -> formatted_path (path)
    // {s} -> config.prompt.color (color for the prompt symbol)
    // {s} -> config.prompt.symbol (prompt symbol)
    // {s} -> reset (reset color code)
    const prompt = try std.fmt.allocPrint(
        allocator,
        "\n{s} {s}{s}{s} ",
        .{
            formatted_path,
            prompt_result.color,
            prompt_result.symbol,
            reset,
        },
    );

    try std.Io.File.stdout().writeStreamingAll(init.io, prompt);
}

test {
    std.testing.refAllDecls(@This());
}
