const std = @import("std");
const testing = std.testing;
const builtin = @import("builtin");
const Config = @import("../config/config.zig").Config;
const PromptContext = @import("../engine/context.zig").PromptContext;
const BufferWriter = @import("../utils/buffer_writer.zig").BufferWriter;
const Shell = @import("../init/root.zig").Shell;
const modules = @import("../modules/registry.zig");
const prompt = @import("../engine/prompt.zig");

pub const Fixture = struct {
    /// Renders any specific module into a buffer using given Config, Context, and Shell.
    pub fn renderModule(
        comptime module_name: []const u8,
        config: Config,
        ctx: PromptContext,
        out_buf: []u8,
    ) ![]const u8 {
        const mod = @field(modules, module_name);
        const mod_cfg = @field(config, module_name);
        var pos: usize = 0;
        const writer = BufferWriter.init(out_buf, &pos);
        try mod.render(writer, mod_cfg, ctx);
        return out_buf[0..pos];
    }

    /// Renders the full prompt into a buffer using given Config, Context, and Shell.
    pub fn renderPrompt(
        config: Config,
        ctx: PromptContext,
        out_buf: []u8,
    ) ![]const u8 {
        var pos: usize = 0;
        const writer = BufferWriter.init(out_buf, &pos);
        try prompt.render(writer, config, ctx);
        return out_buf[0..pos];
    }

    /// Strip ANSI escape sequences and shell zero-width markers (\x01..\x02, %{..%}).
    pub fn stripAnsi(alloc: std.mem.Allocator, text: []const u8) ![]const u8 {
        var buf = try alloc.alloc(u8, text.len);
        var w: usize = 0;
        var i: usize = 0;
        while (i < text.len) {
            if (text[i] == 0x1b and i + 1 < text.len and text[i + 1] == '[') {
                i += 2;
                while (i < text.len and text[i] != 'm') : (i += 1) {}
                if (i < text.len and text[i] == 'm') i += 1;
                continue;
            }
            if (text[i] == 0x01 or text[i] == 0x02) {
                i += 1;
                continue;
            }
            if (text[i] == '%' and i + 1 < text.len and (text[i + 1] == '{' or text[i + 1] == '}')) {
                i += 2;
                continue;
            }
            buf[w] = text[i];
            w += 1;
            i += 1;
        }
        return buf[0..w];
    }

    /// Strict validator that checks whether all ANSI color sequences are correctly
    /// escaped for the target shell without any leaks or invalid control characters.
    pub fn assertValidShellAnsi(rendered: []const u8, shell: Shell) !void {
        var i: usize = 0;
        while (i < rendered.len) {
            // Check for ANSI escape start \x1b[
            if (rendered[i] == 0x1b and i + 1 < rendered.len and rendered[i + 1] == '[') {
                // Find terminating 'm'
                var m_idx: ?usize = null;
                var j: usize = i + 2;
                while (j < rendered.len) : (j += 1) {
                    if (rendered[j] == 'm') {
                        m_idx = j;
                        break;
                    }
                }
                const end_m = m_idx orelse return error.UnterminatedAnsiSequence;

                switch (shell) {
                    .bash => {
                        // Must be preceded by \x01
                        if (i == 0 or rendered[i - 1] != 0x01) {
                            return error.MissingBashZeroWidthStart;
                        }
                        // Must be followed by \x02
                        if (end_m + 1 >= rendered.len or rendered[end_m + 1] != 0x02) {
                            return error.MissingBashZeroWidthEnd;
                        }
                    },
                    .zsh => {
                        // Must be preceded by %{
                        if (i < 2 or rendered[i - 2] != '%' or rendered[i - 1] != '{') {
                            return error.MissingZshZeroWidthStart;
                        }
                        // Must be followed by %}
                        if (end_m + 2 >= rendered.len or rendered[end_m + 1] != '%' or rendered[end_m + 2] != '}') {
                            return error.MissingZshZeroWidthEnd;
                        }
                    },
                    .fish, .powershell, .generic => {
                        // Must NOT be wrapped in \x01..\x02 or %{..%}
                        if (i > 0 and rendered[i - 1] == 0x01) return error.UnexpectedBashMarker;
                        if (i >= 2 and rendered[i - 2] == '%' and rendered[i - 1] == '{') return error.UnexpectedZshMarker;
                    },
                }
                i = end_m + 1;
                continue;
            }

            // General zero-width leaks check for non-wrapped shells
            switch (shell) {
                .fish, .powershell, .generic => {
                    if (rendered[i] == 0x01 or rendered[i] == 0x02) return error.UnexpectedBashMarker;
                    if (rendered[i] == '%' and i + 1 < rendered.len and (rendered[i + 1] == '{' or rendered[i + 1] == '}')) {
                        return error.UnexpectedZshMarker;
                    }
                },
                .bash => {
                    if (rendered[i] == '%' and i + 1 < rendered.len and (rendered[i + 1] == '{' or rendered[i + 1] == '}')) {
                        return error.UnexpectedZshMarker;
                    }
                },
                .zsh => {
                    if (rendered[i] == 0x01 or rendered[i] == 0x02) return error.UnexpectedBashMarker;
                },
            }

            i += 1;
        }
    }

    pub fn execInShell(
        io: std.Io,
        shell: Shell,
        raw_prompt: []const u8,
        out_buf: []u8,
    ) !?[]const u8 {
        const bin: []const u8 = switch (shell) {
            .bash => "bash",
            .zsh => "zsh",
            .fish => "fish",
            .powershell => if (builtin.os.tag == .windows) "powershell.exe" else "pwsh",
            .generic => return error.UnsupportedShell,
        };

        var prompt_env_buf: [4096]u8 = undefined;
        const prompt_env = try std.fmt.bufPrint(&prompt_env_buf, "ZAP_PROMPT={s}", .{raw_prompt});

        const argv: []const []const u8 = switch (shell) {
            .bash => &[_][]const u8{
                "env",
                prompt_env,
                bin,
                "--noprofile",
                "--norc",
                "-c",
                "PS1=\"$ZAP_PROMPT\"; echo -n \"$PS1\"",
            },
            .zsh => &[_][]const u8{
                "env",
                prompt_env,
                bin,
                "-f",
                "+Z",
                "-c",
                "print -nP \"$ZAP_PROMPT\"",
            },
            .fish => &[_][]const u8{
                "env",
                prompt_env,
                bin,
                "--no-config",
                "-c",
                "echo -n \"$ZAP_PROMPT\"",
            },
            .powershell => &[_][]const u8{
                "env",
                prompt_env,
                bin,
                "-NoProfile",
                "-NonInteractive",
                "-Command",
                "[Console]::Out.Write($env:ZAP_PROMPT)",
            },
            .generic => return error.UnsupportedShell,
        };

        var child = std.process.spawn(io, .{
            .argv = argv,
            .stdout = .pipe,
            .stderr = .pipe,
            .stdin = .ignore,
        }) catch |err| switch (err) {
            error.FileNotFound => return null, // Shell binary is not installed on this machine — safely skip
            else => return err,
        };

        var stream_buf: [512]u8 = undefined;
        var reader = child.stdout.?.reader(io, &stream_buf);
        var total_read: usize = 0;

        while (total_read < out_buf.len) {
            const n = reader.interface.readSliceShort(out_buf[total_read..]) catch |err| {
                std.debug.print("[SHELL] Stdout read error: {any}\n", .{err});
                return err;
            };
            if (n == 0) break;
            total_read += n;
        }

        var err_stream_buf: [256]u8 = undefined;
        var err_reader = child.stderr.?.reader(io, &err_stream_buf);
        var err_buf: [2048]u8 = undefined;
        var err_read: usize = 0;
        while (err_read < err_buf.len) {
            const n = err_reader.interface.readSliceShort(err_buf[err_read..]) catch |err| {
                std.debug.print("[SHELL] Stderr read error: {any}\n", .{err});
                return err;
            };
            if (n == 0) break;
            err_read += n;
        }

        const term = child.wait(io) catch return error.ShellExecutionFailed;
        switch (term) {
            .exited => |code| if (code != 0) {
                // Skip if shell is simply not installed (127)
                if (code == 127) {
                    return null;
                }
                std.debug.print(
                    \\
                    \\[SHELL ERROR] {s} exited with code {d}
                    \\[SHELL ERROR] Stderr: {s}
                    \\[SHELL ERROR] Raw Prompt: {s}
                    \\
                , .{ bin, code, err_buf[0..err_read], raw_prompt });
                return error.ShellExecutionFailed;
            },
            else => return error.ShellExecutionFailed,
        }

        return out_buf[0..total_read];
    }

    pub fn testModuleAcrossRealShells(
        comptime module_name: []const u8,
        config: Config,
        base_ctx: PromptContext,
        io: std.Io,
        predicate: *const fn (shell: Shell, rendered: []const u8, term_out: []const u8) anyerror!void,
    ) !void {
        const shells = [_]Shell{ .bash, .zsh, .fish, .powershell };
        var buf: [2048]u8 = undefined;
        var shell_out_buf: [4096]u8 = undefined;

        for (shells) |sh| {
            var ctx = base_ctx;
            ctx.shell = sh;

            const rendered = try renderModule(module_name, config, ctx, &buf);
            try assertValidShellAnsi(rendered, sh);

            const maybe_out = try execInShell(io, sh, rendered, &shell_out_buf);
            if (maybe_out) |out| {
                try predicate(sh, rendered, out);
            }
        }
    }
};
