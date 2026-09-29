const std = @import("std");
const builtin = @import("builtin");
const formatter = @import("../engine/formatter.zig");

pub const PromptContext = @import("../engine/context.zig").PromptContext;

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
        const file = std.Io.Dir.openFileAbsolute(io, "/etc/os-release", .{}) catch {
            const fallback_file = std.Io.Dir.openFileAbsolute(io, "/usr/lib/os-release", .{}) catch return .linux;
            return parseOsReleaseFile(io, fallback_file);
        };
        return parseOsReleaseFile(io, file);
    }

    fn parseOsReleaseFile(io: std.Io, file: std.Io.File) TargetOs {
        defer file.close(io);

        var stream_buf: [4096]u8 = undefined;
        var file_reader = file.reader(io, &stream_buf);

        var content_buf: [1024]u8 = undefined;
        const bytes_read = file_reader.interface.readSliceShort(&content_buf) catch return .linux;
        if (bytes_read == 0) return .linux;

        const content = content_buf[0..bytes_read];
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
    try std.testing.expectEqual(TargetOs.arch, TargetOs.fromDistroId("arch"));
    try std.testing.expectEqual(TargetOs.ubuntu, TargetOs.fromDistroId("\"ubuntu\""));
    try std.testing.expectEqual(TargetOs.fedora, TargetOs.fromDistroId("Fedora"));
    try std.testing.expectEqual(TargetOs.nixos, TargetOs.fromDistroId("nixos"));
    try std.testing.expectEqual(TargetOs.linux, TargetOs.fromDistroId("unknown_distro"));
}

test "default symbols match nerd fonts" {
    try std.testing.expectEqualStrings("󰣇", TargetOs.arch.defaultSymbol());
    try std.testing.expectEqualStrings("󰕈", TargetOs.ubuntu.defaultSymbol());
    try std.testing.expectEqualStrings("", TargetOs.fedora.defaultSymbol());
    try std.testing.expectEqualStrings("", TargetOs.windows.defaultSymbol());
}

test "render os module with custom symbol" {
    var buf: [128]u8 = undefined;
    var pos: usize = 0;
    const writer = @import("../utils/buffer_writer.zig").BufferWriter.init(&buf, &pos);

    const cfg = OsConfig{
        .disabled = false,
        .symbol = "",
        .style = "bold cyan",
    };
    const ctx = PromptContext{
        .cwd = "/home/user",
        .home = "/home/user",
    };

    try render(writer, cfg, ctx);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..pos], "") != null);
}
