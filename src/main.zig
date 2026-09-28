const std = @import("std");

pub const config_mod = @import("config/config.zig");
pub const toml_parser = @import("config/toml_parser.zig");
pub const style = @import("engine/style.zig");
pub const formatter = @import("engine/formatter.zig");
pub const prompt = @import("engine/prompt.zig");
pub const directory = @import("modules/directory.zig");
pub const character = @import("modules/character.zig");
pub const cmd_duration = @import("modules/cmd_duration.zig");
pub const git_branch = @import("modules/git_branch.zig");
pub const git_commit = @import("modules/git_commit.zig");
pub const git_state = @import("modules/git_state.zig");
pub const git_status = @import("modules/git_status.zig");
pub const registry = @import("modules/registry.zig");
pub const context = @import("engine/context.zig");
pub const buffer_writer = @import("utils/buffer_writer.zig");
pub const path_utils = @import("utils/path_utils.zig");
pub const color_utils = @import("utils/color_utils.zig");
pub const git_utils = @import("utils/git_utils.zig");

const Config = config_mod.Config;
const BufferWriter = buffer_writer.BufferWriter;

pub fn main(init: std.process.Init) !void {
    var config = Config{};
    var config_file_buf: [64 * 1024]u8 = undefined;
    toml_parser.loadConfigFile(init.io, init.environ_map, &config, &config_file_buf);

    const exec_args = try parseExecutionArgs(init, init.arena.allocator());

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
        .status_code = exec_args.status_code,
        .cmd_duration = exec_args.cmd_duration,
        .io = init.io,
    });

    // Output the rendered prompt buffer in a single syscall
    try std.Io.File.stdout().writeStreamingAll(init.io, prompt_buf[0..pos]);
}

const ExecutionArgs = struct {
    status_code: u8 = 0,
    cmd_duration: u64 = 0,
};

fn parseExecutionArgs(init: std.process.Init, allocator: std.mem.Allocator) !ExecutionArgs {
    var res = ExecutionArgs{};

    var args = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();

    _ = args.next(); // Skip executable name

    if (args.next()) |status_raw| {
        res.status_code = std.fmt.parseInt(u8, status_raw, 10) catch 0;
    }

    if (args.next()) |duration_raw| {
        res.cmd_duration = std.fmt.parseInt(u64, duration_raw, 10) catch 0;
    } else if (init.environ_map.get("CMD_DURATION")) |cmd_dur_env| {
        res.cmd_duration = std.fmt.parseInt(u64, cmd_dur_env, 10) catch 0;
    }

    return res;
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
