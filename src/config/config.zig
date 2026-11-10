const std = @import("std");
const registry = @import("../modules/registry.zig");
const module = @import("../modules/module.zig");

fn GenerateConfig() type {
    const reg_decls = comptime @typeInfo(registry).@"struct".decls;
    const total_fields = 3 + reg_decls.len;

    comptime var names_buf: [total_fields][]const u8 = undefined;
    comptime var types_buf: [total_fields]type = undefined;
    comptime var attrs_buf: [total_fields]std.builtin.Type.StructField.Attributes = undefined;

    names_buf[0] = "format";
    types_buf[0] = []const u8;
    attrs_buf[0] = .{};

    names_buf[1] = "right_format";
    types_buf[1] = []const u8;
    attrs_buf[1] = .{};

    names_buf[2] = "add_newline";
    types_buf[2] = bool;
    attrs_buf[2] = .{};

    inline for (reg_decls, 0..) |decl, i| {
        const Mod = @field(registry, decl.name);
        const ModCfgType = comptime (module.resolveConfigType(Mod) orelse {
            @compileError("Module '" ++ decl.name ++ "' must export a Config type");
        });

        names_buf[3 + i] = decl.name;
        types_buf[3 + i] = ModCfgType;
        attrs_buf[3 + i] = .{};
    }

    const final_names = names_buf;
    const final_types = types_buf;
    const final_attrs = attrs_buf;

    return @Struct(
        .auto,
        null,
        &final_names,
        &final_types,
        &final_attrs,
    );
}

pub const Config: type = GenerateConfig();

pub fn defaultConfig() Config {
    var cfg: Config = undefined;
    cfg.format = "$directory$git_branch$git_commit$git_state$git_status$cmd_duration$character";
    cfg.right_format = "";
    cfg.add_newline = true;

    inline for (@typeInfo(registry).@"struct".decls) |decl| {
        const Mod = @field(registry, decl.name);
        const ModCfgType = comptime module.resolveConfigType(Mod).?;
        @field(cfg, decl.name) = ModCfgType{};
    }

    return cfg;
}
