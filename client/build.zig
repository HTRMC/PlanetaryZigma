const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const shared = b.dependency("shared", .{ .target = target, .optimize = optimize }).module("shared");
    const yes = b.dependency("yes", .{ .target = target, .optimize = optimize, .x_backend = .xlib }).module("yes");

    const steam_dep = b.dependency("zig_steamworks", .{ .target = target, .optimize = optimize });
    const steam_module = steam_dep.module("steamworks");

    const zgltf = b.dependency("zgltf", .{ .target = target, .optimize = optimize }).module("zgltf");

    const stb_dep = b.dependency("stb", .{});
    const stb = b.addTranslateC(.{
        .root_source_file = stb_dep.path("stb_image.h"),
        .target = target,
        .optimize = optimize,
    });
    stb.addIncludePath(b.dependency("stb", .{}).path("."));

    const system = b.addLibrary(.{
        .name = "system_client",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/system.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "shared", .module = shared },
                .{ .name = "yes", .module = yes },
                .{ .name = "zgltf", .module = zgltf },
                .{ .name = "stb", .module = stb.createModule() },
            },
            .link_libc = true,
        }),
        .use_lld = true,
        .use_llvm = true,
        .linkage = .dynamic,
    });

    system.root_module.addCSourceFile(.{
        .file = b.addWriteFiles().add("stbi_impl.c",
            \\#define STB_IMAGE_IMPLEMENTATION
            \\#include "stb_image.h"
        ),
    });
    system.root_module.addIncludePath(stb_dep.path("."));

    const exe = b.addExecutable(.{
        .name = "client",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "shared", .module = shared },
                .{ .name = "system", .module = system.root_module },
                .{ .name = "yes", .module = yes },
                .{ .name = "steamworks", .module = steam_module },
            },
            .link_libc = true,
        }),
        .use_lld = true,
        .use_llvm = true,
    });

    const vulkandeps = b.dependency("vulkan_headers", .{});
    const vmadep = b.dependency("vma", .{});

    const vulkan_c = b.addTranslateC(.{
        .root_source_file = b.addWriteFiles().add("vma_vulkan.h",
            \\#include <vulkan/vulkan.h>
            \\#include <vk_mem_alloc.h>
        ),
        .target = target,
        .optimize = optimize,
    });
    vulkan_c.addIncludePath(vulkandeps.path("include/"));
    vulkan_c.addIncludePath(vmadep.path("include/"));

    const vulkan = vulkan_c.createModule();
    vulkan.link_libcpp = true;
    for (vulkan_c.include_dirs.items) |include_dir| vulkan.addIncludePath(include_dir.path);

    vulkan.addCSourceFile(.{
        .file = b.addWriteFiles().add("vma_impl.cpp",
            \\#define VMA_STATIC_VULKAN_FUNCTIONS 1
            \\#define VMA_DYNAMIC_VULKAN_FUNCTIONS 0
            \\#define VMA_IMPLEMENTATION
            \\#include <vk_mem_alloc.h>
        ),
        .flags = &.{"-std=c++17"},
    });

    const shaderc_dep = b.dependency("shaderc", .{});
    const shaderc = b.addTranslateC(.{
        .root_source_file = shaderc_dep.path("libshaderc/include/shaderc/shaderc.h"),
        .target = target,
        .optimize = optimize,
    });
    system.root_module.addImport("shaderc", shaderc.createModule());

    system.root_module.addImport("vulkan", vulkan);
    exe.root_module.linkSystemLibrary("vulkan", .{});
    exe.root_module.linkSystemLibrary("shaderc", .{});
    exe.root_module.link_libcpp = true;

    b.installArtifact(system);
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the client");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
}
