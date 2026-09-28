const std = @import("std");
const testing = std.testing;
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
};
