const std = @import("std");
const module = @import("../module.zig");

pub const PythonModule = module.GenericLanguageModule(.{
    .name = "python",
    .symbol = " ",
    .style = "bold yellow",
    .extensions = &.{ ".py", ".ipynb" },
    .files = &.{ "pyproject.toml", "requirements.txt", "Pipfile", "tox.ini", "setup.py", ".python-version", "uv.lock" },
});

pub const Var = PythonModule.Var;
pub const Config = PythonModule.Config;
pub const PythonConfig = Config;
pub const render = PythonModule.render;
pub const buffer_size = PythonModule.buffer_size;
pub const debug = PythonModule.debug;

pub const Harness = @import("../../tests/harness.zig").Harness;

test "unit: python satisfies module contract" {
    comptime module.validateModule(PythonModule);
}

test "integration: python renders symbol when pyproject.toml or .py is present" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.writeFile("pyproject.toml", "[project]\nname = \"app\"\n");
    try h.setConfig(
        \\format = "$python"
        \\add_newline = false
    );

    const out = try h.collect(.generic);
    try Harness.expectContains(out, "");
}
