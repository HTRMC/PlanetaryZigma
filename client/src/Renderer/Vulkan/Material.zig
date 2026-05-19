const std = @import("std");
const vk = @import("vulkan");
const nz = @import("numz");
const Image = @import("Image.zig");
const descriptor = @import("desrciptor.zig");
const Mesh = @import("Mesh.zig");
const Device = @import("device.zig").Logical;
const Pipeline = @import("pipeline.zig").Pipeline;
pub const LoadShader = @import("utils.zig").loadShaderModule;

pub const Pass = enum {
    main_color,
    transparent,
    other,
};

pub const Instance = struct {
    pipeline: *const Pipeline,
    descriptor_set: ?vk.VkDescriptorSet,
    pass_type: Pass,
};

pub const GltfMetallicRoughness = struct {
    opaque_pipeline: *const Pipeline,
    transparent_pipeline: *const Pipeline,
    descriptor_set_layout: vk.VkDescriptorSetLayout,
    writer: descriptor.Writer,

    pub const Constants = extern struct {
        color_factores: nz.Vec4(f32) = undefined,
        metal_rough_factors: nz.Vec4(f32) = undefined,
        extra: [14]nz.Vec4(f32) = undefined,
    };

    pub const Resources = struct {
        color_image: Image,
        color_sampler: vk.VkSampler,
        metal_rough_image: Image,
        metal_rough_sampler: vk.VkSampler,
        data_buffer: vk.VkBuffer,
        data_buffer_offset: vk.VkDeviceSize,
    };

    pub fn initBuildPipelines(gpa: std.mem.Allocator, device: Device, gpu_scene_data_descriptor_layout: descriptor.Layout, draw_image: Image, depth_image: Image) !@This() {
        const mesh_frag_shader: vk.VkShaderModule = try LoadShader(device.handle, "zig-out/shaders/mesh.frag.spv");
        const mesh_vertex_shader: vk.VkShaderModule = try LoadShader(device.handle, "zig-out/shaders/mesh.vert.spv");
        defer vk.vkDestroyShaderModule(device.handle, mesh_frag_shader, null);
        defer vk.vkDestroyShaderModule(device.handle, mesh_vertex_shader, null);

        const matrixRange: vk.VkPushConstantRange = .{
            .offset = 0,
            .size = @sizeOf(Mesh.GPUDrawPushConstants),
            .stageFlags = vk.VK_SHADER_STAGE_VERTEX_BIT,
        };

        const material_layout: descriptor.Layout = try .init(device, &.{
            .{
                .binding = 0,
                .descriptorCount = 1,
                .descriptorType = vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
                .stageFlags = vk.VK_SHADER_STAGE_VERTEX_BIT | vk.VK_SHADER_STAGE_FRAGMENT_BIT,
            },
            .{
                .binding = 1,
                .descriptorCount = 1,
                .descriptorType = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                .stageFlags = vk.VK_SHADER_STAGE_VERTEX_BIT | vk.VK_SHADER_STAGE_FRAGMENT_BIT,
            },
            .{
                .binding = 2,
                .descriptorCount = 1,
                .descriptorType = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                .stageFlags = vk.VK_SHADER_STAGE_VERTEX_BIT | vk.VK_SHADER_STAGE_FRAGMENT_BIT,
            },
        });

        var mesh_pipeline_config: Pipeline.Graphics.Config = .{
            .fragment_shaders = .{
                .module = mesh_frag_shader,
            },
            .vertex_shaders = .{
                .module = mesh_vertex_shader,
            },
            .descriptor_set_layouts = &.{
                gpu_scene_data_descriptor_layout.handle,
                material_layout.handle,
            },
            .push_constants = &.{matrixRange},
        };
        mesh_pipeline_config.viewport_state.scissorCount = 1;
        mesh_pipeline_config.viewport_state.viewportCount = 1;
        mesh_pipeline_config.dynamic_state.dynamicStateCount = 2;
        mesh_pipeline_config.dynamic_state.pDynamicStates = &[_]c_uint{
            vk.VK_DYNAMIC_STATE_VIEWPORT,
            vk.VK_DYNAMIC_STATE_SCISSOR,
        };

        mesh_pipeline_config.render_info.colorAttachmentCount = 1;
        mesh_pipeline_config.render_info.pColorAttachmentFormats = &draw_image.format;
        mesh_pipeline_config.render_info.depthAttachmentFormat = depth_image.format;
        mesh_pipeline_config.enableDepthTesting(vk.VK_TRUE, vk.VK_COMPARE_OP_LESS);

        // mesh_pipeline_config.rasterization_state.polygonMode = vk.VK_POLYGON_MODE_LINE;
        const opaque_pipeline = try gpa.create(Pipeline);
        opaque_pipeline.* = try .initGraphics(device, &mesh_pipeline_config);

        mesh_pipeline_config.setBlendingDestinationColorBlendFactor(vk.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA);
        mesh_pipeline_config.enableDepthTesting(vk.VK_FALSE, vk.VK_COMPARE_OP_LESS);
        const transparent_pipeline = try gpa.create(Pipeline);
        transparent_pipeline.* = try .initGraphics(device, &mesh_pipeline_config);

        return .{
            .opaque_pipeline = opaque_pipeline,
            .transparent_pipeline = transparent_pipeline,
            .descriptor_set_layout = material_layout.handle,
            .writer = .{},
        };
    }

    pub fn deinit(self: *@This(), gpa: std.mem.Allocator, device: Device) void {
        self.opaque_pipeline.deinit(device);
        self.transparent_pipeline.deinit(device);
        gpa.destroy(self.opaque_pipeline);
        gpa.destroy(self.transparent_pipeline);
        vk.vkDestroyDescriptorSetLayout(device.handle, self.descriptor_set_layout, null);
    }

    pub fn writeMaterial(
        self: *@This(),
        device: Device,
        pass: Pass,
        resources: Resources,
        descriptor_allocator: *descriptor.Growable,
    ) !Instance {
        var material_data_instance: Instance = undefined;
        material_data_instance.pass_type = pass;
        if (pass == .transparent) {
            std.debug.print("added transparent_pipeline\n", .{});
            material_data_instance.pipeline = self.transparent_pipeline;
        } else {
            material_data_instance.pipeline = self.opaque_pipeline;
        }
        material_data_instance.descriptor_set = try descriptor_allocator.allocate(device, self.descriptor_set_layout, null);
        self.writer.clear();
        self.writer.appendBuffer(0, resources.data_buffer, @sizeOf(Constants), resources.data_buffer_offset, vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER);
        self.writer.appendImage(1, resources.color_image.vk_imageview, resources.color_sampler, vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER);
        self.writer.appendImage(2, resources.metal_rough_image.vk_imageview, resources.metal_rough_sampler, vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER);
        self.writer.updateSet(device, material_data_instance.descriptor_set.?);
        return material_data_instance;
    }

    // pub fn clearResources(device: vk.VkDevice) void {}
};
