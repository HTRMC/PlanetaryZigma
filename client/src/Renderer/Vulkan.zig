const std = @import("std");
const nz = @import("shared").numz;
const AssetServer = @import("shared").AssetServer;
const system = @import("../system.zig");
const Info = system.Info;
const World = system.World;
const shaderc = @import("shaderc");
const Instance = @import("Vulkan/Instance.zig");
const DebugMessenger = @import("Vulkan/DebugMessenger.zig");
const PhysicalDevice = @import("Vulkan/device.zig").Physical;
const Device = @import("Vulkan/device.zig").Logical;
const Mesh = @import("Vulkan/Mesh.zig");
const Vma = @import("Vulkan/Vma.zig");
const Swapchain = @import("Vulkan/Swapchain.zig");
const Surface = @import("Vulkan/Surface.zig");
const Image = @import("Vulkan/Image.zig");
const Buffer = @import("Vulkan/Buffer.zig");
const descriptor = @import("Vulkan/desrciptor.zig");
const pipeline = @import("Vulkan/pipeline.zig");
const Shader = @import("Vulkan/Shader.zig");
const procs = @import("Vulkan/procs.zig");
const ext = procs.device.ProcTable;

const check = @import("Vulkan/utils.zig").check;

pub const c = @import("vulkan");
pub const Vertex = Mesh.Vertex;

instance: Instance,
debug_messenger: DebugMessenger,
surface: Surface,
physical_device: PhysicalDevice,
device: Device,
vma: Vma,
swapchain: Swapchain,
meshes: std.ArrayList(Mesh) = .empty,

//Temporary
vertex_shader: *Shader,
fragment_shader: *Shader,
desciptor_layout: descriptor.Layout,
pipeline_layout: pipeline.Layout,

pub const InitOptions = struct {
    instance: struct {
        extensions: []const [*:0]const u8,
        layers: []const [*:0]const u8,
    },
    device: struct {
        extensions: []const [*:0]const u8,
    },
    surface: struct {
        data: ?*anyopaque = null,
        init: ?*const fn (c.VkInstance, *anyopaque) anyerror!c.VkSurfaceKHR = null,
    } = .{},
    swapchain: struct {
        width: u32,
        heigth: u32,
    },
};

pub fn init(gpa: std.mem.Allocator, asset_server: *AssetServer, options: InitOptions) !*@This() {
    const self = try gpa.create(@This());

    self.instance = try .init(gpa, options.instance.extensions, options.instance.layers);
    procs.instance.load(self.instance.handle, null);
    self.debug_messenger = try .init(self.instance, .{
        .severities = if (try std.process.Environ.contains(.empty, gpa, "RENDERDOC_CAPFILE")) .{} else .{
            .warning = true,
            .verbose = true,
            .@"error" = true,
            .info = true,
        },
    });
    self.surface = if (options.surface.init != null and options.surface.data != null) .{
        .handle = @ptrCast(try options.surface.init.?(self.instance.handle, options.surface.data.?)),
    } else return error.configSurface;
    self.physical_device = try .pick(self.instance, self.surface.handle);
    self.device = try .init(self.physical_device, options.device.extensions);
    procs.device.load(self.device.handle, null);
    self.vma = try .init(self.instance, self.physical_device, self.device);
    self.swapchain = try .init(gpa, self.vma, self.physical_device, self.device, self.surface, options.swapchain.width, options.swapchain.heigth);

    self.desciptor_layout = try .init(
        self.device,
        &.{.{
            .binding = 0,
            .descriptorCount = @sizeOf(Swapchain.FrameData.GPUScene),
            .descriptorType = c.VK_DESCRIPTOR_TYPE_INLINE_UNIFORM_BLOCK,
            .stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT,
        }},
        c.VK_DESCRIPTOR_SET_LAYOUT_CREATE_DESCRIPTOR_BUFFER_BIT_EXT,
    );
    self.pipeline_layout = try .init(self.device, Shader.PushConstant, self.desciptor_layout);
    self.meshes = .empty;
    try self.meshes.append(gpa, try .init(
        gpa,
        self.vma,
        "box",
        self.device,
        &Mesh.box.indicies_array,
        Mesh.Vertex,
        &Mesh.box.vertex_array,
    ));
    self.vertex_shader = try .init(gpa, self.device, asset_server, .{
        .sType = c.VK_STRUCTURE_TYPE_SHADER_CREATE_INFO_EXT,
        .stage = c.VK_SHADER_STAGE_VERTEX_BIT,
        .nextStage = c.VK_SHADER_STAGE_FRAGMENT_BIT,
        .codeType = c.VK_SHADER_CODE_TYPE_SPIRV_EXT,
        .pSetLayouts = &self.desciptor_layout.handle,
        .setLayoutCount = 1,
        .pushConstantRangeCount = 1,
        .pName = "main",
    }, "shaders/vertex.vert");
    self.fragment_shader = try .init(gpa, self.device, asset_server, .{
        .sType = c.VK_STRUCTURE_TYPE_SHADER_CREATE_INFO_EXT,
        .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT,
        .codeType = c.VK_SHADER_CODE_TYPE_SPIRV_EXT,
        .pSetLayouts = &self.desciptor_layout.handle,
        .setLayoutCount = 1,
        .pushConstantRangeCount = 1,
        .pName = "main",
    }, "shaders/fragment.frag");

    return self;
}

pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
    check(c.vkDeviceWaitIdle(self.device.handle)) catch {};

    for (self.meshes.items) |*mesh| {
        mesh.deinit(gpa, self.vma);
    }
    self.meshes.deinit(gpa);
    self.desciptor_layout.deinit(self.device);
    self.pipeline_layout.deinit(self.device);
    self.vertex_shader.deinit(gpa);
    self.fragment_shader.deinit(gpa);
    self.swapchain.deinit(self.vma, self.device);
    self.vma.deinit();
    self.device.deinit();
    self.surface.deinit(self.instance);
    self.debug_messenger.deinit(self.instance);
    self.instance.deinit();
}

pub fn update(self: *@This(), info: *const Info) !void {
    // const time = data.delta_time;
    // const elapsed_time = data.elapsed_time;
    var image_index: u32 = undefined;
    var current_frame = &self.swapchain.frames[self.swapchain.current_frame_inflight % self.swapchain.frames.len];
    try check(c.vkWaitForFences(self.device.handle, 1, &current_frame.render_fence, 1, 1000000000));
    // std.debug.print("------------ {d} \n", .{image_index});
    const aquire_result = c.vkAcquireNextImageKHR(
        self.device.handle,
        self.swapchain.swapchain,
        1000000000,
        current_frame.swapchain_semaphore,
        null,
        &image_index,
    );
    // std.debug.print("Acquire result={d} image_index={d}\n", .{ aquire_result, image_index });
    switch (aquire_result) {
        c.VK_ERROR_OUT_OF_DATE_KHR,
        => return,
        c.VK_TIMEOUT, c.VK_NOT_READY => return,
        else => {},
    }
    try check(c.vkResetFences(self.device.handle, 1, &current_frame.render_fence));
    const render_semaphore: c.VkSemaphore = self.swapchain.render_semaphores[image_index];
    // try current_frame.descriptor.clearPools(self.device);
    // current_frame.gpu_scene.deinit(self.vma.handle);

    const cmd_buffer = current_frame.command_buffer;
    try check(c.vkResetCommandBuffer(cmd_buffer, 0));
    var cmd_begin_info: c.VkCommandBufferBeginInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    };
    try check(c.vkBeginCommandBuffer(cmd_buffer, &cmd_begin_info));

    try render(self, cmd_buffer, current_frame, info);

    var swapchain_image_barrier: Image.Barrier = .init(cmd_buffer, self.swapchain.images[image_index], c.VK_IMAGE_ASPECT_COLOR_BIT);
    swapchain_image_barrier.transition(c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, c.VK_PIPELINE_STAGE_TRANSFER_BIT, c.VK_ACCESS_TRANSFER_WRITE_BIT);
    self.swapchain.draw_image.copyOntoImage(
        cmd_buffer,
        .{ .vk_image = self.swapchain.images[image_index], .extent = self.swapchain.extent },
    );

    swapchain_image_barrier.transition(c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR, c.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, 0);
    try check(c.vkEndCommandBuffer(cmd_buffer));

    var submit_info: c.VkSubmitInfo2 = .{
        .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO_2,
        .waitSemaphoreInfoCount = 1,
        .pWaitSemaphoreInfos = &.{
            .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO,
            .semaphore = current_frame.swapchain_semaphore,
            .stageMask = c.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT_KHR,
            .value = 0,
        },
        .signalSemaphoreInfoCount = 1,
        .pSignalSemaphoreInfos = &.{
            .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO,
            .semaphore = render_semaphore,
            .stageMask = c.VK_PIPELINE_STAGE_2_ALL_GRAPHICS_BIT,
            .value = 0,
        },
        .commandBufferInfoCount = 1,
        .pCommandBufferInfos = &.{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO,
            .commandBuffer = cmd_buffer,
        },
    };

    try check(c.vkQueueSubmit2(self.device.graphics_queue, 1, &submit_info, current_frame.render_fence));

    var present_info: c.VkPresentInfoKHR = .{
        .sType = c.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
        .pSwapchains = &self.swapchain.swapchain,
        .swapchainCount = 1,
        .pWaitSemaphores = &render_semaphore,
        .waitSemaphoreCount = 1,
        .pImageIndices = &image_index,
    };

    const present_result = c.vkQueuePresentKHR(self.device.graphics_queue, &present_info);

    if (present_result == c.VK_ERROR_OUT_OF_DATE_KHR or present_result == c.VK_SUBOPTIMAL_KHR) {
        return;
        // self.swapchain.recreate(self.physical_device, self.device, self.surface, )
    }
    self.swapchain.current_frame_inflight += 1;
}

pub fn render(self: *@This(), cmd: c.VkCommandBuffer, current_frame: *Swapchain.FrameData, info: *const Info) !void {
    const elapsed_time = info.elapsed_time;
    var draw_image_barrier: Image.Barrier = .init(cmd, self.swapchain.draw_image.vk_image, c.VK_IMAGE_ASPECT_COLOR_BIT);

    draw_image_barrier.transition(
        c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
    );
    var depth_image_barrier: Image.Barrier = .init(cmd, self.swapchain.depth_image.vk_image, c.VK_IMAGE_ASPECT_DEPTH_BIT);
    depth_image_barrier.transition(
        c.VK_IMAGE_LAYOUT_DEPTH_ATTACHMENT_OPTIMAL,
        c.VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT | c.VK_PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT,
        c.VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_READ_BIT | c.VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
    );
    var color_attachment: c.VkRenderingAttachmentInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
        .pNext = null,
        .imageView = self.swapchain.draw_image.vk_imageview,
        .imageLayout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        .resolveMode = c.VK_RESOLVE_MODE_NONE,
        .resolveImageView = null,
        .resolveImageLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
        .loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR,
        .storeOp = c.VK_ATTACHMENT_STORE_OP_STORE,
        .clearValue = .{
            .color = .{
                // .float32 = .{ (@sin(info.elapsed_time) + 1) / 2, (@cos(info.elapsed_time) + 1) / 2, (@tan(info.elapsed_time) + 1) / 2, 1.0 },
                .float32 = .{ 0, 0, 0, 1 },
            },
        },
    };
    var depth_attachment: c.VkRenderingAttachmentInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
        .imageView = self.swapchain.depth_image.vk_imageview,
        .imageLayout = c.VK_IMAGE_LAYOUT_DEPTH_ATTACHMENT_OPTIMAL,
        .loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR,
        .storeOp = c.VK_ATTACHMENT_STORE_OP_STORE,
        .clearValue = .{
            .depthStencil = .{
                .depth = 1,
                .stencil = 0,
            },
        },
    };

    const stages = [_]c.VkShaderStageFlagBits{
        c.VK_SHADER_STAGE_VERTEX_BIT,
        c.VK_SHADER_STAGE_FRAGMENT_BIT,
        c.VK_SHADER_STAGE_TESSELLATION_CONTROL_BIT,
        c.VK_SHADER_STAGE_TESSELLATION_EVALUATION_BIT,
        c.VK_SHADER_STAGE_GEOMETRY_BIT,
    };

    const bound = [_]c.VkShaderEXT{ self.vertex_shader.handle, self.fragment_shader.handle, null, null, null };

    const viewport: c.VkViewport = .{
        .width = @floatFromInt(self.swapchain.draw_image.extent.width),
        .height = @floatFromInt(self.swapchain.draw_image.extent.height),
        .maxDepth = 1,
    };
    const scissor: c.VkRect2D = .{
        .extent = .{
            .width = self.swapchain.draw_image.extent.width,
            .height = self.swapchain.draw_image.extent.height,
        },
    };
    ext.vkCmdBindShadersEXT(cmd, stages.len, &stages[0], &bound[0]);

    ext.vkCmdSetViewportWithCountEXT(cmd, 1, &viewport);
    ext.vkCmdSetScissorWithCountEXT(cmd, 1, &scissor);

    // std.debug.print("time: {d}\n", .{self.elapsed_time});
    const tmp: i32 = @intFromFloat(elapsed_time);
    // std.debug.print("fixed-time: {d}\n", .{tmp});
    if (@mod(tmp, 2) == -1) {
        ext.vkCmdSetPolygonModeEXT(cmd, c.VK_POLYGON_MODE_LINE);
        c.vkCmdSetLineWidth(cmd, 1);
        ext.vkCmdSetCullModeEXT(cmd, c.VK_CULL_MODE_BACK_BIT);
    } else {
        ext.vkCmdSetPolygonModeEXT(cmd, c.VK_POLYGON_MODE_FILL);

        ext.vkCmdSetCullModeEXT(cmd, c.VK_CULL_MODE_BACK_BIT);
    }
    ext.vkCmdSetFrontFaceEXT(cmd, c.VK_FRONT_FACE_COUNTER_CLOCKWISE);
    ext.vkCmdSetDepthTestEnableEXT(cmd, c.VK_TRUE);
    ext.vkCmdSetDepthWriteEnableEXT(cmd, c.VK_TRUE);
    ext.vkCmdSetDepthCompareOpEXT(cmd, c.VK_COMPARE_OP_LESS_OR_EQUAL);
    ext.vkCmdSetPrimitiveTopologyEXT(cmd, c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST);
    ext.vkCmdSetRasterizerDiscardEnableEXT(cmd, c.VK_FALSE);

    ext.vkCmdSetRasterizationSamplesEXT(cmd, c.VK_SAMPLE_COUNT_1_BIT);
    ext.vkCmdSetAlphaToCoverageEnableEXT(cmd, c.VK_TRUE);
    ext.vkCmdSetDepthBiasEnableEXT(cmd, c.VK_FALSE);
    ext.vkCmdSetStencilTestEnableEXT(cmd, c.VK_FALSE);
    ext.vkCmdSetPrimitiveRestartEnableEXT(cmd, c.VK_FALSE);

    const sample_mask: u32 = 0xFF;
    ext.vkCmdSetSampleMaskEXT(cmd, c.VK_SAMPLE_COUNT_1_BIT, &sample_mask);

    const color_blend_enables: c.VkBool32 = c.VK_FALSE;
    const color_blend_component_flags: c.VkColorComponentFlags = c.VK_COLOR_COMPONENT_R_BIT | c.VK_COLOR_COMPONENT_G_BIT | c.VK_COLOR_COMPONENT_B_BIT | c.VK_COLOR_COMPONENT_A_BIT;
    ext.vkCmdSetColorBlendEnableEXT(cmd, 0, 1, &color_blend_enables);
    ext.vkCmdSetColorWriteMaskEXT(cmd, 0, 1, &color_blend_component_flags);

    ext.vkCmdSetDepthBoundsTestEnable(cmd, c.VK_FALSE);
    ext.vkCmdSetDepthClampEnableEXT(cmd, c.VK_FALSE);
    ext.vkCmdSetAlphaToOneEnableEXT(cmd, c.VK_FALSE);
    ext.vkCmdSetLogicOpEnableEXT(cmd, c.VK_FALSE);

    const vertex_input_binding: c.VkVertexInputBindingDescription2EXT = .{
        .sType = c.VK_STRUCTURE_TYPE_VERTEX_INPUT_BINDING_DESCRIPTION_2_EXT,
        .binding = 0,
        .inputRate = c.VK_VERTEX_INPUT_RATE_VERTEX,
        .stride = @sizeOf(Mesh.Vertex),
        .divisor = 1,
    };
    const vertex_attributes = &[_]c.VkVertexInputAttributeDescription2EXT{
        .{
            .sType = c.VK_STRUCTURE_TYPE_VERTEX_INPUT_ATTRIBUTE_DESCRIPTION_2_EXT,
            .location = 0,
            .binding = 0,
            .format = c.VK_FORMAT_R32G32B32_SFLOAT,
            .offset = 0,
        },
        .{
            .sType = c.VK_STRUCTURE_TYPE_VERTEX_INPUT_ATTRIBUTE_DESCRIPTION_2_EXT,
            .location = 1,
            .binding = 0,
            .format = c.VK_FORMAT_R32G32B32_SFLOAT,
            .offset = @sizeOf([4]f32),
        },
        .{
            .sType = c.VK_STRUCTURE_TYPE_VERTEX_INPUT_ATTRIBUTE_DESCRIPTION_2_EXT,
            .location = 2,
            .binding = 0,
            .format = c.VK_FORMAT_R32G32B32A32_SFLOAT,
            .offset = 2 * @sizeOf([4]f32),
        },
    };

    ext.vkCmdSetVertexInputEXT(cmd, 1, &vertex_input_binding, 3, &vertex_attributes[0]);

    var render_info: c.VkRenderingInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_RENDERING_INFO,
        .pNext = null,
        .flags = 0,
        .renderArea = .{
            .offset = .{ .x = 0, .y = 0 },
            .extent = .{
                .height = self.swapchain.draw_image.extent.height,
                .width = self.swapchain.draw_image.extent.width,
            },
        },
        .layerCount = 1,
        .viewMask = 0,
        .colorAttachmentCount = 1,
        .pColorAttachments = &color_attachment,
        .pDepthAttachment = &depth_attachment,
        .pStencilAttachment = null,
    };

    const aspect: f32 = @as(f32, @floatFromInt(self.swapchain.draw_image.extent.width)) / @as(f32, @floatFromInt(self.swapchain.draw_image.extent.height));

    const camera = camera: {
        for (info.world.entities.values()) |*entity| {
            if (entity.flags.camera) break :camera &entity.camera;
        }
        return;
    };
    const view = getViewMatrix(&camera.transform);
    var proj = perspective(camera.fov_rad, aspect, 0.01, 1000);
    const proj_view = proj.mul(view);

    var scene_data: Swapchain.FrameData.GPUScene = .{
        .view_proj = proj_view.d,
        .time = elapsed_time,
    };
    current_frame.gpu_scene.copy(Swapchain.FrameData.GPUScene, (&scene_data)[0..1]);
    var info1: c.VkBufferDeviceAddressInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_BUFFER_DEVICE_ADDRESS_INFO,
        .buffer = current_frame.gpu_scene.buffer,
    };
    const gpu_scene_data = ext.vkGetBufferDeviceAddress(self.device.handle, &info1);
    var info2: c.VkDescriptorBufferBindingInfoEXT = .{
        .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_BUFFER_BINDING_INFO_EXT,
        .address = gpu_scene_data,
        .usage = c.VK_BUFFER_USAGE_RESOURCE_DESCRIPTOR_BUFFER_BIT_EXT,
    };
    ext.vkCmdBindDescriptorBuffersEXT(cmd, 1, &info2);
    var buffer_index: u32 = 0;
    var offset: c.VkDeviceSize = 0;
    ext.vkCmdSetDescriptorBufferOffsetsEXT(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.pipeline_layout.handle, 0, 1, &buffer_index, &offset);

    const identity_matrix: nz.Mat4x4(f32) = .identity;
    ext.vkCmdBeginRendering(cmd, &render_info);
    var push: Shader.PushConstant = .{ .buffer_address = undefined, .model_matrix = identity_matrix.d };
    for (info.world.entities.values()) |*entry| {
        if (!entry.flags.mesh or !entry.flags.transform) continue;
        var mesh_id = entry.mesh.id;
        mesh_id = if (mesh_id >= self.meshes.items.len) 0 else mesh_id;
        const mesh = self.meshes.items[mesh_id];
        const transform = entry.transform;
        // std.log.debug("render-quat: {any}", .{transform.rotation});
        const matrix = transform.toMat4x4();
        push = .{ .buffer_address = mesh.vertex_buffer.gpu_address, .model_matrix = matrix.d };
        c.vkCmdBindIndexBuffer(cmd, mesh.index_buffer.buffer, 0, c.VK_INDEX_TYPE_UINT32);
        c.vkCmdPushConstants(cmd, self.pipeline_layout.handle, c.VK_SHADER_STAGE_VERTEX_BIT, 0, @sizeOf(Shader.PushConstant), &push);
        c.vkCmdDrawIndexed(
            cmd,
            @intCast(mesh.index_buffer.len),
            1,
            0,
            0,
            0,
        );
    }

    ext.vkCmdEndRendering(cmd);

    draw_image_barrier.transition(c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, c.VK_PIPELINE_STAGE_TRANSFER_BIT, c.VK_ACCESS_TRANSFER_READ_BIT);
}

pub fn resize(self: *@This(), gpa: std.mem.Allocator, width: u32, height: u32) !void {
    try self.swapchain.recreate(
        gpa,
        self.vma,
        self.physical_device,
        self.device,
        self.surface,
        width,
        height,
    );
}

pub fn createMesh(self: *@This(), gpa: std.mem.Allocator, name: []const u8, indices: []u32, verices: []Mesh.Vertex) !usize {
    const mesh = try Mesh.init(
        gpa,
        self.vma,
        name,
        self.device,
        indices,
        Mesh.Vertex,
        verices,
    );
    try self.meshes.append(
        gpa,
        mesh,
    );
    return (self.meshes.items.len - 1);
}

fn getViewMatrix(transform: *const nz.Transform3D(f32)) nz.Mat4x4(f32) {
    const inv_rotation = transform.rotation.conjugate().toMat4x4();
    const inv_translation = nz.Mat4x4(f32).translate(-transform.position);

    return inv_rotation.mul(inv_translation);
}

fn perspective(fovy_rad: f32, aspect: f32, near: f32, far: f32) nz.Mat4x4(f32) {
    const f = 1.0 / std.math.tan(fovy_rad / 2.0);
    return .new(.{
        f / aspect, 0, 0, 0,
        0, -f, 0, 0, // flip Y for Vulkan
        0, 0, far / (near - far),          -1, // <- note near-far here
        0, 0, (far * near) / (near - far), 0,
    });
}
