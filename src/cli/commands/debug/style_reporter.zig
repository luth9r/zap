const std = @import("std");
const registry = @import("../../../modules/registry.zig");
const context = @import("../../../engine/context.zig");
const config_mod = @import("../../../config/config.zig");
const toml_parser = @import("../../../config/toml_parser.zig");
const style_mod = @import("../../../engine/style.zig");
const prompt_reporter = @import("prompt_reporter.zig");
const DebugContext = context.DebugContext;

pub fn printStyleDebug(init: std.process.Init, writer: anytype, dctx: DebugContext) !void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const config_path_opt = toml_parser.resolveExistingConfigPath(init.io, &path_buf, init.environ_map);

    var config = config_mod.defaultConfig();
    var config_file_buf: [64 * 1024]u8 = undefined;

    if (config_path_opt) |config_path| {
        const file = if (std.fs.path.isAbsolute(config_path))
            std.Io.Dir.openFileAbsolute(init.io, config_path, .{}) catch null
        else
            std.Io.Dir.cwd().openFile(init.io, config_path, .{}) catch null;

        if (file) |f| {
            var handle = f;
            defer handle.close(init.io);
            var stream_buf: [4096]u8 = undefined;
            var reader = handle.reader(init.io, &stream_buf);
            const bytes_read = reader.interface.readSliceShort(&config_file_buf) catch 0;
            if (bytes_read > 0) {
                toml_parser.parseToml(&config, config_file_buf[0..bytes_read]);
            }
        }
    }

    const decls = @typeInfo(registry).@"struct".decls;

    if (dctx.json) {
        try writer.writeAll("{ \"target\": \"style\", \"module_styles\": {");
        var first = true;
        inline for (decls) |decl| {
            const mod_cfg = @field(config, decl.name);
            if (@hasField(@TypeOf(mod_cfg), "style")) {
                if (!first) try writer.writeAll(", ");
                const style_str = mod_cfg.style;
                var ansi_buf: [128]u8 = undefined;
                const parsed = style_mod.Style.parse(style_str);
                const ansi = parsed.toAnsiBuf(&ansi_buf) orelse "";
                try writer.print("\"{s}\": {{ \"spec\": \"{s}\", \"ansi\": \"", .{ decl.name, style_str });
                try prompt_reporter.writeEscapedAnsi(writer, ansi, true);
                try writer.writeAll("\" }");
                first = false;
            }
        }
        try writer.writeAll("} }\n");
        return;
    }

    try writer.writeAll(
        \\⚡ Zap ANSI Style & Color Palette Inspector
        \\
        \\Standard 8 Colors:
        \\  
    );
    const std_colors = [_]struct { name: []const u8, code: []const u8 }{
        .{ .name = "black", .code = "\x1b[30m" },
        .{ .name = "red", .code = "\x1b[31m" },
        .{ .name = "green", .code = "\x1b[32m" },
        .{ .name = "yellow", .code = "\x1b[33m" },
        .{ .name = "blue", .code = "\x1b[34m" },
        .{ .name = "purple", .code = "\x1b[35m" },
        .{ .name = "cyan", .code = "\x1b[36m" },
        .{ .name = "white", .code = "\x1b[37m" },
    };
    for (std_colors) |c| {
        try writer.print("{s}██ {s}\x1b[0m  ", .{ c.code, c.name });
    }

    try writer.writeAll("\n\nBright 8 Colors:\n  ");
    const bright_colors = [_]struct { name: []const u8, code: []const u8 }{
        .{ .name = "bright-black", .code = "\x1b[90m" },
        .{ .name = "bright-red", .code = "\x1b[91m" },
        .{ .name = "bright-green", .code = "\x1b[92m" },
        .{ .name = "bright-yellow", .code = "\x1b[93m" },
        .{ .name = "bright-blue", .code = "\x1b[94m" },
        .{ .name = "bright-purple", .code = "\x1b[95m" },
        .{ .name = "bright-cyan", .code = "\x1b[96m" },
        .{ .name = "bright-white", .code = "\x1b[97m" },
    };
    for (bright_colors) |c| {
        try writer.print("{s}██ {s}\x1b[0m  ", .{ c.code, c.name });
    }

    try writer.writeAll("\n\nText Modifiers:\n  \x1b[1mbold\x1b[0m   \x1b[2mdimmed\x1b[0m   \x1b[3mitalic\x1b[0m   \x1b[4munderline\x1b[0m   \x1b[7minverted\x1b[0m   \x1b[9mstrikethrough\x1b[0m\n\nConfigured Module Styles:\n");

    inline for (decls) |decl| {
        const mod_cfg = @field(config, decl.name);
        if (@hasField(@TypeOf(mod_cfg), "style")) {
            const style_str = mod_cfg.style;
            var ansi_buf: [128]u8 = undefined;
            const parsed = style_mod.Style.parse(style_str);
            const ansi = parsed.toAnsiBuf(&ansi_buf) orelse "";
            const is_valid = style_mod.Style.validate(style_str) == null;
            try writer.print("  {s} {s:<15} style = \"{s:<18}\" -> {s}Sample Text\x1b[0m", .{
                if (is_valid) "✔" else "✖",
                decl.name,
                style_str,
                ansi,
            });
            if (dctx.verbose) {
                try writer.writeAll("  (");
                try prompt_reporter.writeEscapedAnsi(writer, ansi, false);
                try writer.writeByte(')');
            }
            try writer.writeByte('\n');
        }
    }
}
