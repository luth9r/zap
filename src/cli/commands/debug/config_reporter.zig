const std = @import("std");
const registry = @import("../../../modules/registry.zig");
const context = @import("../../../engine/context.zig");
const config_mod = @import("../../../config/config.zig");
const toml_parser = @import("../../../config/toml_parser.zig");
const prompt_engine = @import("../../../engine/prompt.zig");
const fs = @import("../../../utils/fs.zig");
const parse_utils = @import("../../../utils/parse_utils.zig");
const DebugContext = context.DebugContext;

pub fn printConfigDebug(init: std.process.Init, writer: anytype, dctx: DebugContext) !void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const config_path_opt = toml_parser.resolveExistingConfigPath(init.io, &path_buf, init.environ_map);
    const config_exists = if (config_path_opt) |p| fs.fileExists(init.io, p) else false;

    var config = config_mod.defaultConfig();
    var config_file_buf: [64 * 1024]u8 = undefined;
    var file_size: usize = 0;

    if (config_exists) {
        file_size = toml_parser.loadConfigFromPath(init.io, config_path_opt.?, &config, &config_file_buf);
    }

    const active_mask = prompt_engine.computeActiveModulesMask(config.format) | prompt_engine.computeActiveModulesMask(config.right_format);
    const decls = @typeInfo(registry).@"struct".decls;

    if (dctx.json) {
        var j_path: [std.fs.max_path_bytes]u8 = undefined;
        var j_fmt: [1024]u8 = undefined;
        var j_rfmt: [1024]u8 = undefined;
        try writer.print(
            \\{{ "config_path": {s}{s}{s}, "file_size": {d}, "format": "{s}", "right_format": "{s}", "add_newline": {}, "active_modules": [
        , .{
            if (config_exists) "\"" else "",
            if (config_exists) parse_utils.escapeJsonBuf(&j_path, config_path_opt.?) else "null",
            if (config_exists) "\"" else "",
            file_size,
            parse_utils.escapeJsonBuf(&j_fmt, config.format),
            parse_utils.escapeJsonBuf(&j_rfmt, config.right_format),
            config.add_newline,
        });

        var first_active = true;
        inline for (decls, 0..) |decl, idx| {
            const is_active = (active_mask & (@as(u64, 1) << @as(u6, @intCast(idx)))) != 0;
            if (is_active) {
                if (!first_active) try writer.writeAll(", ");
                try writer.print("\"{s}\"", .{decl.name});
                first_active = false;
            }
        }

        try writer.writeAll("], \"inactive_modules\": [");
        var first_inactive = true;
        inline for (decls, 0..) |decl, idx| {
            const is_active = (active_mask & (@as(u64, 1) << @as(u6, @intCast(idx)))) != 0;
            if (!is_active) {
                if (!first_inactive) try writer.writeAll(", ");
                try writer.print("\"{s}\"", .{decl.name});
                first_inactive = false;
            }
        }
        try writer.writeAll("]");

        if (dctx.verbose) {
            try writer.writeAll(", \"verbose\": true, \"modules\": {");
            var first_mod = true;
            inline for (decls) |decl| {
                if (!first_mod) try writer.writeAll(", ");
                const mod_cfg = @field(config, decl.name);
                try writer.print("\"{s}\": {{", .{decl.name});
                var first_f = true;
                inline for (@typeInfo(@TypeOf(mod_cfg)).@"struct".fields) |f| {
                    const val = @field(mod_cfg, f.name);
                    if (f.type == []const u8) {
                        if (!first_f) try writer.writeAll(", ");
                        try writer.print("\"{s}\": \"", .{f.name});
                        try parse_utils.writeJsonEscaped(writer, val);
                        try writer.writeByte('"');
                        first_f = false;
                    } else if (f.type == bool) {
                        if (!first_f) try writer.writeAll(", ");
                        try writer.print("\"{s}\": {}", .{ f.name, val });
                        first_f = false;
                    } else if (f.type == usize or f.type == u32 or f.type == u64) {
                        if (!first_f) try writer.writeAll(", ");
                        try writer.print("\"{s}\": {d}", .{ f.name, val });
                        first_f = false;
                    }
                }
                try writer.writeAll("}");
                first_mod = false;
            }
            try writer.writeAll("}");
        }

        try writer.writeAll(" }\n");
    } else {
        try writer.print(
            \\⚡ Zap Config Inspector{s}
            \\
            \\Config File:
            \\  Loaded From:     {s}
            \\  File Size:       {d} bytes
            \\
            \\Root Settings:
            \\  Add Newline:     {}
            \\  Format:          "{s}"
            \\  Right Format:    "{s}"
            \\
            \\Active Modules:
            \\
        , .{
            if (dctx.verbose) " (Verbose Mode)" else "",
            if (config_exists) config_path_opt.? else "Default built-in configuration (no file found)",
            file_size,
            config.add_newline,
            config.format,
            config.right_format,
        });

        inline for (decls, 0..) |decl, idx| {
            const is_active = (active_mask & (@as(u64, 1) << @as(u6, @intCast(idx)))) != 0;
            if (is_active) {
                try writer.print("  ✔ {s}\n", .{decl.name});
            }
        }

        try writer.writeAll("\nInactive (Skipped by bitmask):\n");
        inline for (decls, 0..) |decl, idx| {
            const is_active = (active_mask & (@as(u64, 1) << @as(u6, @intCast(idx)))) != 0;
            if (!is_active) {
                try writer.print("  · {s}\n", .{decl.name});
            }
        }

        if (dctx.verbose) {
            try writer.writeAll("\nModule Configurations (Verbose):\n");
            inline for (decls) |decl| {
                const mod_cfg = @field(config, decl.name);
                try writer.print("  [{s}]\n", .{decl.name});
                inline for (@typeInfo(@TypeOf(mod_cfg)).@"struct".fields) |f| {
                    const val = @field(mod_cfg, f.name);
                    if (f.type == []const u8) {
                        try writer.print("    {s:<18}: \"{s}\"\n", .{ f.name, val });
                    } else if (f.type == bool) {
                        try writer.print("    {s:<18}: {}\n", .{ f.name, val });
                    } else if (f.type == usize or f.type == u32 or f.type == u64) {
                        try writer.print("    {s:<18}: {d}\n", .{ f.name, val });
                    }
                }
                try writer.writeAll("\n");
            }
        } else {
            try writer.writeAll("\n");
        }
    }
}
