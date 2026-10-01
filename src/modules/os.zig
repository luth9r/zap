const std = @import("std");
const testing = std.testing;
const builtin = @import("builtin");
const formatter = @import("../engine/formatter.zig");
const fs = @import("../utils/fs.zig");

pub const Config = @import("../config/config.zig").Config;
pub const Fixture = @import("../tests/fixture.zig").Fixture;
pub const PromptContext = @import("../engine/context.zig").PromptContext;
pub const Shell = @import("../init/root.zig").Shell;
pub const Harness = @import("../tests/harness.zig").Harness;

pub const OsConfig = struct {
    format: []const u8 = "[$symbol]($style) ",
    style: []const u8 = "bold white",
    // Custom symbol override. If empty (""), automatically detected from current OS / distro.
    symbol: []const u8 = "",
    disabled: bool = true,
};
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

    pub fn fromDistroId(raw_id: []const u8) TargetOs {
        var id = raw_id;
        if (id.len >= 2 and ((id[0] == '"' and id[id.len - 1] == '"') or (id[0] == '\'' and id[id.len - 1] == '\''))) {
            id = id[1 .. id.len - 1];
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

    try formatter.formatTemplateWriter(writer, config.format, .{
        .style = config.style,
        .shell = ctx.shell,
        .vars = &[_]formatter.Variable{
            .{ .name = "symbol", .value = symbol },
            .{ .name = "style", .value = config.style },
        },
    });
}

test "fromDistroId resolves common distros" {
    try testing.expectEqual(TargetOs.arch, TargetOs.fromDistroId("arch"));
    try testing.expectEqual(TargetOs.ubuntu, TargetOs.fromDistroId("\"ubuntu\""));
    try testing.expectEqual(TargetOs.fedora, TargetOs.fromDistroId("Fedora"));
    try testing.expectEqual(TargetOs.nixos, TargetOs.fromDistroId("nixos"));
    try testing.expectEqual(TargetOs.linux, TargetOs.fromDistroId("unknown_distro"));
}

test "default symbols match nerd fonts" {
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
