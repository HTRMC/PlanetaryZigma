const std = @import("std");
pub const c = @import("vulkan");
// const vulkanC = @import("vulkan");
const Instance = @import("Instance.zig");
const PhysicalDevice = @import("device.zig").Physical;
const Device = @import("device.zig").Logical;
const check = @import("utils.zig").check;

pub const Allocator = c.VmaAllocator;
pub const Allocation = c.VmaAllocation;
pub const AllocationInfo = c.VmaAllocationInfo;

handle: c.VmaAllocator = undefined,

pub fn init(instance: Instance, physical_device: PhysicalDevice, device: Device) !@This() {
    var vma_info: c.VmaAllocatorCreateInfo = .{
        .physicalDevice = @ptrCast(physical_device.handle),
        .device = @ptrCast(device.handle),
        .instance = @ptrCast(instance.handle),
        .flags = c.VMA_ALLOCATOR_CREATE_BUFFER_DEVICE_ADDRESS_BIT,
        .pVulkanFunctions = null,
    };

    var vulkan_mem_alloc: c.VmaAllocator = undefined;
    try check(c.vmaCreateAllocator(&vma_info, &vulkan_mem_alloc));

    return .{
        .handle = vulkan_mem_alloc,
    };
}

pub fn deinit(self: @This()) void {
    c.vmaDestroyAllocator(self.handle);
}
