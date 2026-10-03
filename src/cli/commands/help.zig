const std = @import("std");
const build_options = @import("build_options");
const BufferWriter = @import("../../utils/buffer_writer.zig").BufferWriter;

pub fn executeHelp(io: std.Io) !void {
    var buf: [4096]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);
    try printHelp(writer);
    try std.Io.File.stdout().writeStreamingAll(io, buf[0..pos]);
}

pub fn printHelp(writer: anytype) !void {
    try writer.writeAll(
        \\Zap - Zero-heap, sub-millisecond shell prompt engine
        \\
        \\USAGE:
        \\    zap [COMMAND] [OPTIONS]
        \\
        \\COMMANDS:
        \\    prompt                  Render the prompt string (default command)
        \\    init <shell>            Print shell initialization script
        \\    init <shell> --install  Install Zap prompt hook into shell configuration
        \\    validate [path]         Validate TOML configuration and format templates
        \\    list-modules            List all available prompt modules and their metadata
        \\    debug [target]          Inspect internal diagnostic state (e.g. 'debug git')
        \\    help, --help, -h        Print this help message
        \\    version, --version, -v  Print version information
        \\
        \\OPTIONS for 'prompt':
        \\    --status, -s <code >      Exit code of the previous command (default: 0)
        \\    --duration, -d <ms>       Execution duration of the previous command in ms
        \\    --shell, -sh <shell>      Target shell (bash, zsh, fish, powershell, generic)
        \\    --config, -c <path>       Custom path to configuration file (default: ~/.config/zap/zap.toml)
        \\
        \\OPTIONS for 'debug':
        \\    --verbose, -v           Show detailed diagnostic breakdown (index entries, hashes, timing)
        \\    --json                  Output diagnostic data in JSON format
        \\    --output, -o <path>     Write output directly to specified file
        \\
        \\EXAMPLES:
        \\    zap prompt --status 0 --duration 1500 --shell bash
        \\    zap init zsh
        \\    zap init bash --install
        \\    zap validate
        \\    zap validate ~/.config/zap/zap.toml
        \\    zap debug git
        \\    zap debug git --json -o report.json
        \\    zap debug config
        \\    zap debug env
        \\    zap debug bench
        \\    zap debug bench --json
        \\
    );
}

const testing = std.testing;
const Harness = @import("../../tests/harness.zig").Harness;

test "integration: zap --help and -h" {
    var h = try Harness.create(testing.allocator);
    defer h.destroy();

    const out_long = try h.execZap(&.{"--help"});
    try Harness.expectContains(out_long, "USAGE:");
    try Harness.expectContains(out_long, "COMMANDS:");
    try Harness.expectContains(out_long, "OPTIONS");

    const out_short = try h.execZap(&.{"-h"});
    try Harness.expectContains(out_short, "USAGE:");

    const out_word = try h.execZap(&.{"help"});
    try Harness.expectContains(out_word, "USAGE:");
}
