const std = @import("std");
const module = @import("../module.zig");

pub const DotnetModule = module.GenericLanguageModule(.{
    .name = "dotnet",
    .symbol = "󰪮 ",
    .style = "bold blue",
    .extensions = &.{ ".csproj", ".fsproj", ".vbproj", ".sln", ".slnx", ".cs", ".fs" },
    .files = &.{ "global.json", "Directory.Build.props", "Directory.Build.targets", "Directory.Packages.props", "project.json", "packages.config" },
});

pub const Var = DotnetModule.Var;
pub const Config = DotnetModule.Config;
pub const DotnetConfig = Config;
pub const render = DotnetModule.render;
pub const buffer_size = DotnetModule.buffer_size;
pub const debug = DotnetModule.debug;

pub const Harness = @import("../../tests/harness.zig").Harness;

test "unit: dotnet satisfies module contract" {
    comptime module.validateModule(DotnetModule);
}

test "integration: dotnet renders symbol when .csproj or global.json is present" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.writeFile("App.csproj", "<Project Sdk=\"Microsoft.NET.Sdk\" />\n");
    try h.setConfig(
        \\format = "$dotnet"
        \\add_newline = false
    );

    const out = try h.collect(.generic);
    try Harness.expectContains(out, "󰪮");
}
