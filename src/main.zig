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
pub const os = @import("modules/os.zig");
pub const registry = @import("modules/registry.zig");
pub const context = @import("engine/context.zig");
pub const buffer_writer = @import("utils/buffer_writer.zig");
pub const path_utils = @import("utils/path_utils.zig");
pub const git_utils = @import("utils/git_utils.zig");
pub const init_mod = @import("init/root.zig");

const Config = config_mod.Config;
const BufferWriter = buffer_writer.BufferWriter;

pub const Command = union(enum) {
    init: struct {
        shell: init_mod.Shell,
        exe_name: []const u8 = "zap",
    },
    prompt: struct {
        status_code: u8 = 0,
        cmd_duration: u64 = 0,
        shell: init_mod.Shell = .generic,
    },
};

pub fn main(init: std.process.Init) !void {
    const cmd = try parseCommand(init, init.arena.allocator());

    switch (cmd) {
        .init => |init_args| {
            var script_buf: [8192]u8 = undefined;
            var pos: usize = 0;
            const writer = BufferWriter.init(&script_buf, &pos);
            try init_mod.renderInitScript(writer, init_args.shell, init_args.exe_name);
            try std.Io.File.stdout().writeStreamingAll(init.io, script_buf[0..pos]);
        },
        .prompt => |prompt_args| {
            var config = Config{};
            var config_file_buf: [64 * 1024]u8 = undefined;
            toml_parser.loadConfigFile(init.io, init.environ_map, &config, &config_file_buf);

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
                .status_code = prompt_args.status_code,
                .cmd_duration = prompt_args.cmd_duration,
                .shell = prompt_args.shell,
                .io = init.io,
            });

            // Output the rendered prompt buffer in a single syscall
            try std.Io.File.stdout().writeStreamingAll(init.io, prompt_buf[0..pos]);
        },
    }
}

fn parseCommand(init: std.process.Init, allocator: std.mem.Allocator) !Command {
    var args = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();

    const raw_exe = args.next() orelse "zap";
    const exe_basename = std.fs.path.basename(raw_exe);

    const first_arg = args.next() orelse {
        var p = Command{ .prompt = .{} };
        if (init.environ_map.get("CMD_DURATION")) |cmd_dur_env| {
            p.prompt.cmd_duration = std.fmt.parseInt(u64, cmd_dur_env, 10) catch 0;
        }
        return p;
    };

    if (std.ascii.eqlIgnoreCase(first_arg, "init")) {
        const shell_name = args.next() orelse "generic";
        const target_shell = init_mod.Shell.parse(shell_name) orelse .generic;
        return Command{ .init = .{
            .shell = target_shell,
            .exe_name = if (exe_basename.len > 0) exe_basename else "zap",
        } };
    }

    var res = Command{ .prompt = .{} };
    var positional_idx: usize = 0;

    var current_arg: ?[]const u8 = first_arg;
    if (std.ascii.eqlIgnoreCase(first_arg, "prompt")) {
        current_arg = args.next();
    }

    while (current_arg) |arg| : (current_arg = args.next()) {
        if (std.mem.eql(u8, arg, "--status") or std.mem.eql(u8, arg, "-s")) {
            if (args.next()) |val| {
                res.prompt.status_code = std.fmt.parseInt(u8, val, 10) catch 0;
            }
        } else if (std.mem.eql(u8, arg, "--duration") or std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--cmd-duration")) {
            if (args.next()) |val| {
                res.prompt.cmd_duration = std.fmt.parseInt(u64, val, 10) catch 0;
            }
        } else if (std.mem.eql(u8, arg, "--shell") or std.mem.eql(u8, arg, "-sh")) {
            if (args.next()) |val| {
                res.prompt.shell = init_mod.Shell.parse(val) orelse .generic;
            }
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (positional_idx == 0) {
                res.prompt.status_code = std.fmt.parseInt(u8, arg, 10) catch 0;
                positional_idx += 1;
            } else if (positional_idx == 1) {
                res.prompt.cmd_duration = std.fmt.parseInt(u64, arg, 10) catch 0;
                positional_idx += 1;
            }
        }
    }

    if (res.prompt.cmd_duration == 0) {
        if (init.environ_map.get("CMD_DURATION")) |cmd_dur_env| {
            res.prompt.cmd_duration = std.fmt.parseInt(u64, cmd_dur_env, 10) catch 0;
        }
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
    _ = @import("tests/shell_integration_test.zig");
    _ = @import("tests/harness.zig");
}
