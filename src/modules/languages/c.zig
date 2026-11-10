const std = @import("std");
const module = @import("../module.zig");

pub const CModule = module.GenericLanguageModule(.{
    .name = "c",
    .symbol = " ",
    .style = "bold blue",
    .extensions = &.{ ".c", ".h", ".cpp", ".hpp", ".cc", ".cxx", ".hxx" },
    .files = &.{ "CMakeLists.txt", "Makefile", "meson.build", "configure.ac", "compile_commands.json", "conanfile.txt", "conanfile.py", "vcpkg.json" },
});

pub const Var = CModule.Var;
pub const Config = CModule.Config;
pub const CConfig = Config;
pub const render = CModule.render;
pub const buffer_size = CModule.buffer_size;
pub const debug = CModule.debug;

pub const Harness = @import("../../tests/harness.zig").Harness;

test "unit: c satisfies module contract" {
    comptime module.validateModule(CModule);
}

test "integration: c renders symbol when CMakeLists.txt is present" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.writeFile("CMakeLists.txt", "cmake_minimum_required(VERSION 3.20)\n");
    try h.setConfig(
        \\format = "$c"
        \\add_newline = false
    );

    const out = try h.collect(.generic);
    try Harness.expectContains(out, "");
}
