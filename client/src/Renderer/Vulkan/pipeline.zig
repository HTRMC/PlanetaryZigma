const std = @import("std");
const c = @import("vulkan");
const Device = @import("device.zig").Logical;
const descriptor = @import("desrciptor.zig");
const check = @import("utils.zig").check;

pub const Layout = struct {
    handle: c.VkPipelineLayout,
    pub fn init(
        device: Device,
        comptime PushConstant: type,
        descriptor_layout: []const descriptor.Layout,
    ) !@This() {
        const ranges: c.VkPushConstantRange = .{
            .stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT,
            .offset = 0,
            .size = @sizeOf(PushConstant),
        };

        //TODO: do comptime?
        var vulkan_desctiptor_handles: [16]c.VkDescriptorSetLayout = undefined;
        for (0..descriptor_layout.len) |i| {
            vulkan_desctiptor_handles[i] = descriptor_layout[i].handle;
        }

        var layout_create_info: c.VkPipelineLayoutCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            .pSetLayouts = &vulkan_desctiptor_handles[0],
            .setLayoutCount = @intCast(descriptor_layout.len),
            .pPushConstantRanges = &ranges,
            .pushConstantRangeCount = 1,
        };

        var layout: c.VkPipelineLayout = undefined;
        try check(c.vkCreatePipelineLayout(device.handle, &layout_create_info, null, &layout));
        return .{
            .handle = layout,
        };
    }

    pub fn deinit(self: *@This(), device: Device) void {
        c.vkDestroyPipelineLayout(device.handle, self.handle, null);
    }
};
