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
        \\    --shell, -sh <shell>      Target shell (bash, zsh, fish, powershell, cmd, generic)
        \\    --config, -c <path>       Custom path to configuration file (default: ~/.config/zap/zap.toml)
        \\    --no-newline              Suppress leading newline (used for first prompt / after clear)
        \\    --right, -r               Render right-aligned prompt using 'right_format'
        \\
        \\TARGETS for 'debug':
        \\    all, modules            Inspect diagnostic state of all registered modules (default)
        \\    <module>                Inspect a single module (e.g. 'directory', 'git_status', 'zig_lang')
        \\    git                     Inspect Git modules (use -v for full index & file tree breakdown)
        \\    config                  Inspect active/inactive modules bitmask (use -v for full config dump)
        \\    prompt                  Inspect isolated module outputs, visible width, and raw ANSI escapes
        \\    timings, profile        Single-pass per-module and pipeline execution profiler (µs)
        \\    bench                   Multi-pass statistical benchmark (min, p50, p95, p99, max, throughput)
        \\    style, colors           Render live ANSI color palette and preview configured module styles
        \\    env                     Inspect terminal capabilities ($TERM, TrueColor, UTF-8, env vars)
        \\    shell                   Inspect shell RC hooks and init scripts (use -v to preview script)
        \\
        \\OPTIONS for 'debug':
        \\    --verbose, -v           Show detailed diagnostic breakdown (index entries, raw ANSI, scripts)
        \\    --json                  Output diagnostic data in JSON format
        \\    --iterations, -n <num>  Number of benchmark iterations for 'debug bench' (default: 100)
        \\    --output, -o <path>     Write output directly to specified file
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
