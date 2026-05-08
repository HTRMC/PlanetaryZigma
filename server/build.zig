const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const io = b.graph.io;
    std.Io.Dir.cwd().deleteTree(io, "zig-out/lib/") catch unreachable;
    const zphysics = b.dependency("zphysics", .{
        .use_double_precision = false,
        .enable_cross_platform_determinism = true,
        .shared = true,
    });

    const shared = b.dependency("shared", .{ .target = target, .optimize = optimize }).module("shared");
    const steam = b.dependency("zig_steamworks", .{ .target = target, .optimize = optimize }).module("steamworks");

    const time = std.Io.Timestamp.now(io, .real);
    const system = b.addLibrary(.{
        .name = b.fmt("system_server_{d}", .{time}),
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/system.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "shared", .module = shared },

                .{ .name = "zphy", .module = zphysics.module("root") },
            },
            .link_libc = true,
        }),
        .linkage = .dynamic,
    });

    system.root_module.linkLibrary(zphysics.artifact("joltc"));

    b.installArtifact(system);

    const exe = b.addExecutable(.{
        .name = "server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "shared", .module = shared },
                .{ .name = "system", .module = system.root_module },
                .{ .name = "steamworks", .module = steam },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the server");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
}
