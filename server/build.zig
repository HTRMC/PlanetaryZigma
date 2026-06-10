const std = @import("std");

pub fn build(b: *std.Build) void {
    // const target = b.standardTargetOptions(.{});
    //TODO: remove once Zig 0.16.0 works properly with GCC 16.1.1
    const target = b.standardTargetOptions(.{
        .default_target = .{
            .cpu_arch = .x86_64,
            .os_tag = .linux,
            .abi = .gnu,
            .glibc_version = .{ .major = 2, .minor = 39, .patch = 0 },
        },
    });
    const optimize = b.standardOptimizeOption(.{});
    const zphysics = b.dependency("zphysics", .{
        .use_double_precision = false,
        .enable_cross_platform_determinism = true,
        .shared = true,
    });

    const shared = b.dependency("shared", .{ .target = target, .optimize = optimize }).module("shared");
    const steam_dep = b.dependency("zig_steamworks", .{ .target = target, .optimize = optimize });
    const steam_module = steam_dep.module("steamworks");

    const system = b.addLibrary(.{
        .name = "system_server",
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
                .{ .name = "steamworks", .module = steam_module },
            },
        }),
    });
    //TODO: remove once Zig 0.16.0 works properly with GCC 16.1.1
    exe.root_module.addRPath(steam_dep.path("steamworks/public/steam/lib/linux64"));
    exe.root_module.addRPath(steam_dep.path("steamworks/redistributable_bin/linux64"));

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the server");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
}
