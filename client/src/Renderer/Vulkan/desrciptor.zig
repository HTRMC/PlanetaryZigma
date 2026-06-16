const std = @import("std");
const c = @import("vulkan");
const Func = @import("utils.zig").Func;
const Device = @import("device.zig").Logical;
const check = @import("utils.zig").check;
const tracy = @import("ztracy");

pub const Layout = struct {
    handle: c.VkDescriptorSetLayout,
    count: u32,

    pub fn init(device: Device, bindings: []const c.VkDescriptorSetLayoutBinding, descriptor_flags: u32) !@This() {
        const tracy_scope = tracy.zone(@src());
        defer tracy_scope.end();
        var info: c.VkDescriptorSetLayoutCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
            .pBindings = &bindings[0],
            .bindingCount = @intCast(bindings.len),
            .flags = descriptor_flags,
        };

        var set: c.VkDescriptorSetLayout = undefined;
        try check(c.vkCreateDescriptorSetLayout(
            device.handle,
            &info,
            null,
            &set,
        ));
        return .{
            .handle = set,
            .count = @intCast(bindings.len),
        };
    }

    pub fn deinit(self: @This(), device: Device) void {
        const tracy_scope = tracy.zone(@src());
        defer tracy_scope.end();
        c.vkDestroyDescriptorSetLayout(device.handle, self.handle, null);
    }
};
