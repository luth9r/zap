const std = @import("std");
const testing = std.testing;
const Config = @import("../config/config.zig").Config;
const PromptContext = @import("../engine/context.zig").PromptContext;
const BufferWriter = @import("../utils/buffer_writer.zig").BufferWriter;
const Shell = @import("../init/root.zig").Shell;
const modules = @import("../modules/registry.zig");
const prompt = @import("../engine/prompt.zig");
const platform = @import("../utils/platform.zig");

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
                    .fish, .powershell, .cmd, .generic => {
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
                .fish, .powershell, .cmd, .generic => {
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

    const ENV_ZAP_PROMPT = "ZAP_PROMPT";

    pub fn execInShell(
        io: std.Io,
        shell: Shell,
        raw_prompt: []const u8,
        out_buf: []u8,
    ) !?[]const u8 {
        if (platform.is_windows and shell != .powershell) return null;

        const argv: []const []const u8 = switch (shell) {
            .bash => &.{ "bash", "--noprofile", "--norc", "-c", "PS1=\"$ZAP_PROMPT\"; echo -n \"$PS1\"" },
            .zsh => &.{ "zsh", "-f", "+Z", "-c", "print -nP \"$ZAP_PROMPT\"" },
            .fish => &.{ "fish", "--no-config", "-c", "echo -n \"$ZAP_PROMPT\"" },
            .powershell => &.{ platform.powershell_bin, "-NoProfile", "-NonInteractive", "-Command", "[Console]::Out.Write($env:ZAP_PROMPT)" },
            .cmd, .generic => return null,
        };

        var fba_buf: [8192]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&fba_buf);
        const env_vars = [_]platform.EnvEntry{
            .{ .key = ENV_ZAP_PROMPT, .value = raw_prompt },
        };
        defer if (platform.is_windows) platform.setEnvWindows(ENV_ZAP_PROMPT, null);

        var child = platform.spawnWithEnv(io, fba.allocator(), null, &env_vars, argv) catch |err| switch (err) {
            error.FileNotFound => return null, // Shell binary is not installed on this machine — safely skip
            else => return err,
        };

        var err_buf: [2048]u8 = undefined;
        const total_read = platform.readStreamToBuf(io, child.stdout.?, out_buf);
        const err_read = platform.readStreamToBuf(io, child.stderr.?, &err_buf);

        const term = child.wait(io) catch return null;
        switch (term) {
            .exited => |code| if (code != 0) {
                // Skip if shell is not installed (127) or not executable (126)
                if (code == 127 or code == 126) {
                    return null;
                }
                std.debug.print(
                    \\
                    \\[SHELL ERROR] {s} exited with code {d}
                    \\[SHELL ERROR] Stderr: {s}
                    \\[SHELL ERROR] Raw Prompt: {s}
                    \\
                , .{ argv[0], code, err_buf[0..err_read], raw_prompt });
                return error.ShellExecutionFailed;
            },
            .signal => |sig| {
                // Shell killed by environment / sandbox signal (e.g. SIGABRT, SIGSYS) - skip external execution
                std.debug.print("[SHELL WARN] {s} killed by signal {d}, skipping subshell execution\n", .{ argv[0], sig });
                return null;
            },
            else => return null,
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
        const shells = [_]Shell{ .bash, .zsh, .fish, .powershell, .cmd };
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
