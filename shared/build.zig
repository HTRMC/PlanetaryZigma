const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const numz = b.dependency("numz", .{ .target = target, .optimize = optimize }).module("numz");
    const steamworks = b.dependency("zig_steamworks", .{ .target = target, .optimize = optimize }).module("steamworks");

    const shared = b.addModule("shared", .{
        .root_source_file = b.path("root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "numz", .module = numz },
            .{ .name = "steamworks", .module = steamworks },
        },
    });

    const tests = b.addTest(.{ .root_module = shared });
    const test_step = b.step("test", "Run shared tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
