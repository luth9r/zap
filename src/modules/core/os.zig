const std = @import("std");
const testing = std.testing;
const builtin = @import("builtin");
const formatter = @import("../../engine/formatter.zig");
const fs = @import("../../utils/fs.zig");

const Fixture = @import("../../tests/fixture.zig").Fixture;
pub const PromptContext = @import("../../engine/context.zig").PromptContext;
pub const DebugContext = @import("../../engine/context.zig").DebugContext;
pub const Shell = @import("../../init/root.zig").Shell;
const Harness = @import("../../tests/harness.zig").Harness;

pub const Var = enum { symbol };

pub const OsConfig = struct {
    format: []const u8 = "[$symbol]($style) ",
    style: []const u8 = "bold white",
    // Custom symbol override. If empty (""), automatically detected from current OS / distro.
    symbol: []const u8 = "",
    disabled: bool = true,
};

pub const Config = OsConfig;
pub const TargetOs = enum {
    windows,
    macos,

    alpine,
    arch,
    archcraft,
    artix,
    centos,
    debian,
    elementary,
    endeavouros,
    fedora,
    gentoo,
    kali,
    manjaro,
    mint,
    nixos,
    opensuse,
    pop,
    raspbian,
    redhat,
    rocky,
    slackware,
    ubuntu,
    void,

    linux,
    unknown,

    pub fn defaultSymbol(self: TargetOs) []const u8 {
        return switch (self) {
            .windows => "",
            .macos => "󰀵",

            .alpine => "",
            .arch => "󰣇",
            .archcraft => "",
            .artix => "",
            .centos => "",
            .debian => "",
            .elementary => "",
            .endeavouros => "",
            .fedora => "",
            .gentoo => "󰣨",
            .kali => "",
            .manjaro => "",
            .mint => "󰣭",
            .nixos => "",
            .opensuse => "",
            .pop => "",
            .raspbian => "",
            .redhat => "󱄛",
            .rocky => "",
            .slackware => "",
            .ubuntu => "󰕈",
            .void => "",

            .linux => "",
            .unknown => "?",
        };
    }

    const distro_alias_map = std.StaticStringMapWithEql(TargetOs, std.static_string_map.eqlAsciiIgnoreCase).initComptime(.{
        .{ "linuxmint", .mint },
        .{ "rhel", .redhat },
        .{ "redhatenterpriselinux", .redhat },
        .{ "opensuse-leap", .opensuse },
        .{ "opensuse-tumbleweed", .opensuse },
        .{ "opensuse-microos", .opensuse },
        .{ "popos", .pop },
        .{ "pop_os", .pop },
        .{ "archlinux", .arch },
        .{ "elementaryos", .elementary },
        .{ "rockylinux", .rocky },
        .{ "voidlinux", .void },
    });

    pub fn fromDistroId(raw_id: []const u8) TargetOs {
        const id = @import("../../config/toml_parser.zig").unquoteRaw(raw_id);

        if (distro_alias_map.get(id)) |aliased| {
            return aliased;
        }

        inline for (@typeInfo(TargetOs).@"enum".fields) |field| {
            if (std.ascii.eqlIgnoreCase(field.name, id)) {
                return @enumFromInt(field.value);
            }
        }
        return .linux;
    }

    pub fn detectLinuxDistro(io: std.Io) TargetOs {
        if (parseOsReleaseFile(io, "/etc/os-release")) |os| return os;
        if (parseOsReleaseFile(io, "/usr/lib/os-release")) |os| return os;
        return .linux;
    }

    fn parseOsReleaseFile(io: std.Io, path: []const u8) ?TargetOs {
        var content_buf: [1024]u8 = undefined;
        const content = fs.readSmallFile(io, path, &content_buf) orelse return null;
        var line_it = std.mem.splitScalar(u8, content, '\n');
        while (line_it.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (std.mem.startsWith(u8, line, "ID=")) {
                const val = std.mem.trim(u8, line[3..], " \t\r");
                return fromDistroId(val);
            }
        }
        return .linux;
    }

    pub fn detectCurrent(io: std.Io) TargetOs {
        return switch (builtin.os.tag) {
            .windows => .windows,
            .macos => .macos,
            .linux => detectLinuxDistro(io),
            else => .unknown,
        };
    }
};

pub fn render(
    writer: anytype,
    config: OsConfig,
    ctx: PromptContext,
) !void {
    if (config.disabled) return;

    const symbol = if (config.symbol.len > 0)
        config.symbol
    else blk: {
        const io = ctx.io orelse return;
        const os_type = TargetOs.detectCurrent(io);
        break :blk os_type.defaultSymbol();
    };

    try formatter.formatTemplateWriter(writer, config.format, formatter.FormatContext(Var){
        .style = config.style,
        .shell = ctx.shell,
        .vars = &.{
            .{ .name = .symbol, .value = symbol },
        },
    });
}

pub fn debug(writer: anytype, dctx: DebugContext) !void {
    const io = dctx.prompt.io orelse return;
    const os_type = TargetOs.detectCurrent(io);
    const os_name = @tagName(os_type);
    const sym = os_type.defaultSymbol();

    if (dctx.json) {
        try writer.print(
            \\{{ "module": "os", "detected_os": "{s}", "symbol": "{s}" }}
            \\
        , .{ os_name, sym });
    } else {
        try writer.print(
            \\⚡ Module: os
            \\  Detected OS: {s}
            \\  Symbol:      {s}
            \\
        , .{ os_name, sym });
    }
}

test "unit: fromDistroId resolves common distros" {
    try testing.expectEqual(TargetOs.arch, TargetOs.fromDistroId("arch"));
    try testing.expectEqual(TargetOs.arch, TargetOs.fromDistroId("archlinux"));
    try testing.expectEqual(TargetOs.ubuntu, TargetOs.fromDistroId("\"ubuntu\""));
    try testing.expectEqual(TargetOs.fedora, TargetOs.fromDistroId("Fedora"));
    try testing.expectEqual(TargetOs.nixos, TargetOs.fromDistroId("nixos"));
    try testing.expectEqual(TargetOs.mint, TargetOs.fromDistroId("linuxmint"));
    try testing.expectEqual(TargetOs.redhat, TargetOs.fromDistroId("rhel"));
    try testing.expectEqual(TargetOs.opensuse, TargetOs.fromDistroId("opensuse-tumbleweed"));
    try testing.expectEqual(TargetOs.pop, TargetOs.fromDistroId("pop_os"));
    try testing.expectEqual(TargetOs.linux, TargetOs.fromDistroId("unknown_distro"));
}

test "unit: default symbols match nerd fonts" {
    try testing.expectEqualStrings("󰣇", TargetOs.arch.defaultSymbol());
    try testing.expectEqualStrings("󰕈", TargetOs.ubuntu.defaultSymbol());
    try testing.expectEqualStrings("", TargetOs.fedora.defaultSymbol());
    try testing.expectEqualStrings("", TargetOs.windows.defaultSymbol());
}

test "integration: os is disabled by default" {
    var h = try Harness.create(testing.allocator);
    defer h.destroy();

    try h.setConfig(
        \\format = "$os"
        \\add_newline = false
    );
    const out = try h.collect(.generic);
    try testing.expectEqual(@as(usize, 0), out.len);
}

test "integration: os enabled with custom symbol and ANSI wrapping" {
    var h = try Harness.create(testing.allocator);
    defer h.destroy();

    try h.setConfig(
        \\format = "$os"
        \\add_newline = false
        \\
        \\[os]
        \\disabled = false
        \\symbol = ""
        \\style = "bold yellow"
    );

    const out = try h.collectAllShells();
    try Harness.expectContains(out, "");
}

test "integration: os custom template format" {
    var h = try Harness.create(testing.allocator);
    defer h.destroy();

    try h.setConfig(
        \\format = "$os"
        \\add_newline = false
        \\
        \\[os]
        \\disabled = false
        \\format = "on [$symbol]($style) "
        \\symbol = "NixOS"
        \\style = "cyan"
    );

    const out = try h.collectAllShells();
    try Harness.expectVisibleText(out, "on NixOS");
}

test "integration: os auto-detects system and renders non-empty" {
    var h = try Harness.create(testing.allocator);
    defer h.destroy();

    try h.setConfig(
        \\format = "[$os]"
        \\add_newline = false
        \\
        \\[os]
        \\disabled = false
    );
    const out = try h.collectAllShells();
    try Harness.expectNotEmpty(out);
    try Harness.expectContains(out, "[");
    try Harness.expectContains(out, "]");
}

test "integration: os in full prompt composed with directory and character" {
    var h = try Harness.create(testing.allocator);
    defer h.destroy();

    try h.setConfig(
        \\format = "$os$directory$character"
        \\add_newline = false
        \\
        \\[os]
        \\disabled = false
        \\symbol = "OS"
    );

    const out = try h.collectAllShells();
    try Harness.expectNotEmpty(out);
    try Harness.expectContains(out, "OS");
    try Harness.expectContains(out, "❯");
}
