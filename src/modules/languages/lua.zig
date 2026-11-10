const std = @import("std");
const module = @import("../module.zig");

pub const LuaModule = module.GenericLanguageModule(.{
    .name = "lua",
    .symbol = " ",
    .style = "bold blue",
    .extensions = &.{".lua"},
    .files = &.{ ".lua-version", "stylua.toml", ".stylua.toml", ".luacheckrc" },
});

pub const Var = LuaModule.Var;
pub const Config = LuaModule.Config;
pub const LuaConfig = Config;
pub const render = LuaModule.render;
pub const buffer_size = LuaModule.buffer_size;
pub const debug = LuaModule.debug;

pub const Harness = @import("../../tests/harness.zig").Harness;

test "unit: lua satisfies module contract" {
    comptime module.validateModule(LuaModule);
}

test "integration: lua renders symbol when .lua file is present" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.writeFile("init.lua", "print('hello')\n");
    try h.setConfig(
        \\format = "$lua"
        \\add_newline = false
    );

    const out = try h.collect(.generic);
    try Harness.expectContains(out, "");
}
