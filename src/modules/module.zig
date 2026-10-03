const std = @import("std");
const formatter = @import("../engine/formatter.zig");
const git_utils = @import("../utils/git_utils.zig");
const BufferWriter = @import("../utils/buffer_writer.zig").BufferWriter;

pub const PromptContext = @import("../engine/context.zig").PromptContext;
pub const DebugContext = @import("../engine/context.zig").DebugContext;

/// Validates that a type conforms to the Zap Module compile-time interface.
/// A valid module must provide:
/// - A configuration struct (either `Config` or `<Name>Config`)
/// - A `render` function: `fn (writer: anytype, config: ConfigType, ctx: PromptContext) !void`
/// - Optional `is_git_dependent: bool`
/// - Optional `buffer_size: usize`
pub fn validateModule(comptime Mod: type) void {
    if (!@hasDecl(Mod, "render")) {
        @compileError(@typeName(Mod) ++ " must implement `pub fn render(writer: anytype, config: Config, ctx: PromptContext) !void`");
    }

    const ConfigType = resolveConfigType(Mod) orelse {
        @compileError(@typeName(Mod) ++ " must export a `Config` struct (or `<Name>Config`)");
    };

    if (@typeInfo(ConfigType) != .@"struct") {
        @compileError(@typeName(Mod) ++ ".Config must be a struct type");
    }

    if (@hasDecl(Mod, "is_git_dependent")) {
        if (@TypeOf(Mod.is_git_dependent) != bool) {
            @compileError(@typeName(Mod) ++ ".is_git_dependent must be a bool");
        }
    }

    if (@hasDecl(Mod, "buffer_size")) {
        if (@TypeOf(Mod.buffer_size) != usize) {
            @compileError(@typeName(Mod) ++ ".buffer_size must be a usize");
        }
    }
}

/// Resolves the configuration struct type for a module.
pub fn resolveConfigType(comptime Mod: type) ?type {
    if (@hasDecl(Mod, "Config")) {
        const T = Mod.Config;
        if (@TypeOf(T) == type and @typeInfo(T) == .@"struct") {
            return T;
        }
    }

    // Fallback: check declarations ending with "Config"
    inline for (@typeInfo(Mod).@"struct".decls) |decl| {
        if (std.mem.endsWith(u8, decl.name, "Config")) {
            const T = @field(Mod, decl.name);
            if (@TypeOf(T) == type and @typeInfo(T) == .@"struct") {
                return T;
            }
        }
    }
    return null;
}

const fs = @import("../utils/fs.zig");

/// Specification for a declarative language / tool prompt module.
pub const LanguageSpec = struct {
    name: []const u8,
    symbol: []const u8,
    style: []const u8 = "bold yellow",
    extensions: []const []const u8 = &.{},
    files: []const []const u8 = &.{},
    default_format: []const u8 = "[$symbol$version]($style) ",
    buffer_size: usize = 256,
    // Maximum parent directory levels to traverse upwards (default = 8)
    max_scan_depth: usize = 8,
};

/// Generic builder creating a zero-allocation language / tool module from a specification.
pub fn GenericLanguageModule(comptime spec: LanguageSpec) type {
    return struct {
        pub const Var = enum { symbol, version, style };

        pub const Config = struct {
            format: []const u8 = spec.default_format,
            symbol: []const u8 = spec.symbol,
            style: []const u8 = spec.style,
            version: []const u8 = "",
            disabled: bool = false,
        };

        pub const buffer_size: usize = spec.buffer_size;

        /// Fast check whether any relevant file or extension exists in cwd,
        /// or project manifest files in parent directories up to git repo root.
        pub fn detect(io: std.Io, ctx: PromptContext) bool {
            // 1. Direct check in cwd for explicit manifest/config files
            if (fs.anySubpathExists(io, ctx.cwd, spec.files)) return true;

            // 2. If extensions are specified, check current directory entries
            if (spec.extensions.len > 0 and fs.hasFileWithExtension(io, ctx.cwd, spec.extensions)) {
                return true;
            }

            // 3. Fast upward traversal: check manifest files in parent dirs up to git root (capped by max_scan_depth)
            const repo_root = if (ctx.git_dir) |git_dir| git_utils.gitDirToRepoRoot(git_dir) else null;
            if (fs.scanParentDirsForFiles(io, ctx.cwd, ctx.home, repo_root, spec.files, spec.max_scan_depth)) {
                return true;
            }

            return false;
        }

        pub fn render(
            writer: anytype,
            config: Config,
            ctx: PromptContext,
        ) !void {
            if (config.disabled) return;
            const io = ctx.io orelse return;

            if (!detect(io, ctx)) return;

            try formatter.formatTemplateWriter(writer, config.format, formatter.FormatContext(Var){
                .style = config.style,
                .shell = ctx.shell,
                .vars = &.{
                    .{ .name = .symbol, .value = config.symbol },
                    .{ .name = .version, .value = config.version },
                    .{ .name = .style, .value = config.style },
                },
            });
        }

        pub fn debug(writer: anytype, dctx: DebugContext) !void {
            const io = dctx.prompt.io orelse return;
            const repo_root = if (dctx.prompt.git_dir) |git_dir| git_utils.gitDirToRepoRoot(git_dir) else null;
            const match_detail = fs.detectDetailed(io, dctx.prompt.cwd, dctx.prompt.home, repo_root, spec.files, spec.extensions, spec.max_scan_depth);

            if (dctx.json) {
                try writer.print(
                    \\{{ "module": "{s}", "detected": {}, "verbose": {}, "matched": "{s}", "matched_path": "{s}", "depth": {d}, "files": [
                , .{
                    spec.name,
                    match_detail.matched,
                    dctx.verbose,
                    match_detail.getMatchedFile(),
                    match_detail.getMatchedPath(),
                    match_detail.depth,
                });
                for (spec.files, 0..) |file, idx| {
                    if (idx > 0) try writer.writeAll(", ");
                    try writer.print("\"{s}\"", .{file});
                }
                try writer.writeAll("], \"extensions\": [");
                for (spec.extensions, 0..) |ext, idx| {
                    if (idx > 0) try writer.writeAll(", ");
                    try writer.print("\"{s}\"", .{ext});
                }
                try writer.print("], \"cwd\": \"{s}\" }}\n", .{dctx.prompt.cwd});
            } else {
                try writer.print(
                    \\⚡ Module: {s}
                    \\  Detected:   {}
                , .{ spec.name, match_detail.matched });

                if (dctx.verbose or match_detail.matched) {
                    if (match_detail.matched) {
                        try writer.print(
                            \\
                            \\  Matched:    {s} (depth: {d})
                            \\  Path:       {s}
                        , .{ match_detail.getMatchedFile(), match_detail.depth, match_detail.getMatchedPath() });
                    }
                }

                try writer.print(
                    \\
                    \\  CWD:        {s}
                    \\  Files:      
                , .{ dctx.prompt.cwd });
                for (spec.files, 0..) |file, idx| {
                    if (idx > 0) try writer.writeAll(", ");
                    try writer.print("{s}", .{file});
                }
                try writer.writeAll("\n  Extensions: ");
                for (spec.extensions, 0..) |ext, idx| {
                    if (idx > 0) try writer.writeAll(", ");
                    try writer.print("{s}", .{ext});
                }
                try writer.writeAll("\n\n");
            }
        }
    };
}

/// Specification for a file or directory presence module.
pub const FileSpec = struct {
    name: []const u8,
    symbol: []const u8,
    style: []const u8 = "bold cyan",
    files: []const []const u8 = &.{},
    default_format: []const u8 = "[$symbol]($style) ",
    buffer_size: usize = 256,
    // Maximum parent directory levels to traverse upwards (default = 8)
    max_scan_depth: usize = 8,
};

/// Generic builder for file/presence-based prompt modules.
pub fn GenericFileModule(comptime spec: FileSpec) type {
    return struct {
        pub const Var = enum { symbol, style };

        pub const Config = struct {
            format: []const u8 = spec.default_format,
            symbol: []const u8 = spec.symbol,
            style: []const u8 = spec.style,
            disabled: bool = false,
        };

        pub const buffer_size: usize = spec.buffer_size;

        pub fn detect(io: std.Io, ctx: PromptContext) bool {
            if (fs.anySubpathExists(io, ctx.cwd, spec.files)) return true;
            const repo_root = if (ctx.git_dir) |git_dir| git_utils.gitDirToRepoRoot(git_dir) else null;
            if (fs.scanParentDirsForFiles(io, ctx.cwd, ctx.home, repo_root, spec.files, spec.max_scan_depth)) {
                return true;
            }
            return false;
        }

        pub fn render(
            writer: anytype,
            config: Config,
            ctx: PromptContext,
        ) !void {
            if (config.disabled) return;
            const io = ctx.io orelse return;

            if (!detect(io, ctx)) return;

            try formatter.formatTemplateWriter(writer, config.format, formatter.FormatContext(Var){
                .style = config.style,
                .shell = ctx.shell,
                .vars = &.{
                    .{ .name = .symbol, .value = config.symbol },
                    .{ .name = .style, .value = config.style },
                },
            });
        }

        pub fn debug(writer: anytype, dctx: DebugContext) !void {
            const io = dctx.prompt.io orelse return;
            const repo_root = if (dctx.prompt.git_dir) |git_dir| git_utils.gitDirToRepoRoot(git_dir) else null;
            const match_detail = fs.detectDetailed(io, dctx.prompt.cwd, dctx.prompt.home, repo_root, spec.files, &.{}, spec.max_scan_depth);

            if (dctx.json) {
                try writer.print(
                    \\{{ "module": "{s}", "detected": {}, "verbose": {}, "matched": "{s}", "matched_path": "{s}", "depth": {d}, "files": [
                , .{
                    spec.name,
                    match_detail.matched,
                    dctx.verbose,
                    match_detail.getMatchedFile(),
                    match_detail.getMatchedPath(),
                    match_detail.depth,
                });
                for (spec.files, 0..) |file, idx| {
                    if (idx > 0) try writer.writeAll(", ");
                    try writer.print("\"{s}\"", .{file});
                }
                try writer.print("], \"cwd\": \"{s}\" }}\n", .{dctx.prompt.cwd});
            } else {
                try writer.print(
                    \\⚡ Module: {s}
                    \\  Detected:   {}
                , .{ spec.name, match_detail.matched });

                if (dctx.verbose or match_detail.matched) {
                    if (match_detail.matched) {
                        try writer.print(
                            \\
                            \\  Matched:    {s} (depth: {d})
                            \\  Path:       {s}
                        , .{ match_detail.getMatchedFile(), match_detail.depth, match_detail.getMatchedPath() });
                    }
                }

                try writer.print(
                    \\
                    \\  CWD:        {s}
                    \\  Files:      
                , .{ dctx.prompt.cwd });
                for (spec.files, 0..) |file, idx| {
                    if (idx > 0) try writer.writeAll(", ");
                    try writer.print("{s}", .{file});
                }
                try writer.writeAll("\n\n");
            }
        }
    };
}

test "unit: validateModule on valid module" {
    const ValidMod = struct {
        pub const Config = struct {
            format: []const u8 = "test",
        };
        pub const is_git_dependent: bool = false;
        pub const buffer_size: usize = 128;
        pub fn render(writer: anytype, config: Config, ctx: PromptContext) !void {
            _ = config;
            _ = ctx;
            try writer.writeAll("ok");
        }
    };

    comptime validateModule(ValidMod);
}

test "unit: GenericLanguageModule creation and detection" {
    const TestLang = GenericLanguageModule(.{
        .name = "test_lang",
        .symbol = "TL ",
        .extensions = &.{".tl"},
        .files = &.{"tl.config"},
    });

    comptime validateModule(TestLang);

    var buf: [256]u8 = undefined;
    var pos: usize = 0;
    const writer = BufferWriter.init(&buf, &pos);

    const cfg = TestLang.Config{};
    const ctx = PromptContext{
        .cwd = "/test",
        .home = "/test",
    };

    // When io is null, detection safely exits without rendering
    try TestLang.render(writer, cfg, ctx);
    try std.testing.expectEqual(@as(usize, 0), pos);
}
