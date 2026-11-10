const std = @import("std");
const module = @import("../module.zig");

pub const JavaModule = module.GenericLanguageModule(.{
    .name = "java",
    .symbol = " ",
    .style = "bold red",
    .extensions = &.{ ".java", ".class", ".jar", ".gradle", ".clj" },
    .files = &.{ "pom.xml", "build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts", "build.sbt", ".java-version", "mvnw", "gradlew" },
});

pub const Var = JavaModule.Var;
pub const Config = JavaModule.Config;
pub const JavaConfig = Config;
pub const render = JavaModule.render;
pub const buffer_size = JavaModule.buffer_size;
pub const debug = JavaModule.debug;

pub const Harness = @import("../../tests/harness.zig").Harness;

test "unit: java satisfies module contract" {
    comptime module.validateModule(JavaModule);
}

test "integration: java renders symbol when pom.xml is present" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.writeFile("pom.xml", "<project></project>\n");
    try h.setConfig(
        \\format = "$java"
        \\add_newline = false
    );

    const out = try h.collect(.generic);
    try Harness.expectContains(out, "");
}

test "integration: java does not trigger on hidden .gradle directory" {
    var h = try Harness.create(std.testing.allocator);
    defer h.destroy();

    try h.writeFile(".gradle/caches/info.txt", "cache");
    try h.setConfig(
        \\format = "$java"
        \\add_newline = false
    );

    const out = try h.collect(.generic);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

