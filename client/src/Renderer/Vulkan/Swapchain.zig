const std = @import("std");
const c = @import("vulkan");
const Vma = @import("Vma.zig");
const Func = @import("utils.zig").Func;
const PhysicalDevice = @import("device.zig").Physical;
const Device = @import("device.zig").Logical;
const Buffer = @import("Buffer.zig");
const Surface = @import("Surface.zig");
const Image = @import("Image.zig");
const check = @import("utils.zig").check;

swapchain: c.VkSwapchainKHR,
present_mode: c.VkPresentModeKHR,
images: [16]c.VkImage,
render_semaphores: [16]c.VkSemaphore,
image_count: u32,
format: c.VkFormat,
extent: c.VkExtent3D,
draw_image: Image,
depth_image: Image,
ui_index_buffer: Buffer,

current_frame_inflight: u32 = 0,
frames: [max_frames_inflight]FrameData = undefined,

const max_frames_inflight: usize = 3;
const max_ui_quads: usize = 1024;

pub fn init(
    gpa: std.mem.Allocator,
    vma: Vma,
    physical_device: PhysicalDevice,
    device: Device,
    surface: Surface,
    width: u32,
    height: u32,
) !@This() {
    const present_mode = try getPresentMode(gpa, physical_device, surface);
    const surface_format = try surface.getFormat(gpa, physical_device);
    const swapchain = try create(physical_device, device, surface, surface_format, present_mode, width, height);

    var image_count: u32 = undefined;
    try check(c.vkGetSwapchainImagesKHR(device.handle, swapchain, &image_count, null));
    if (image_count > 16) @panic("More than 16 VkImages\n");

    var vk_images: [16]c.VkImage = undefined;
    try check(c.vkGetSwapchainImagesKHR(device.handle, swapchain, &image_count, &vk_images[0]));

    var semaphoreCreateInfo: c.VkSemaphoreCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
    };
    var render_semaphores: [16]c.VkSemaphore = undefined;
    for (0..image_count) |i| {
        var new_render_semaphore: c.VkSemaphore = undefined;
        try check(c.vkCreateSemaphore(device.handle, &semaphoreCreateInfo, null, &new_render_semaphore));
        render_semaphores[i] = new_render_semaphore;
    }

    var frames: [max_frames_inflight]FrameData = undefined;
    for (&frames) |*frame| {
        frame.* = try .init(vma, device);
        // std.debug.print("PTR: {*}\n", .{&frame.gpu_scene.buffer});
    }

    const actual_extent: c.VkExtent2D = try surface.getExtent(physical_device, width, height);
    const extent_3d: c.VkExtent3D = .{ .width = actual_extent.width, .height = actual_extent.height, .depth = 1 };

    const draw_image: Image = try .init(
        vma,
        device,
        c.VK_FORMAT_R16G16B16A16_SFLOAT,
        extent_3d,
        c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT |
            c.VK_IMAGE_USAGE_TRANSFER_DST_BIT |
            c.VK_IMAGE_USAGE_STORAGE_BIT |
            c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
        c.VK_IMAGE_ASPECT_COLOR_BIT,
        false,
    );
    const depth_image: Image = try .init(
        vma,
        device,
        c.VK_FORMAT_D32_SFLOAT,
        extent_3d,
        c.VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT,
        c.VK_IMAGE_ASPECT_DEPTH_BIT,
        false,
    );

    const ui_index_buffer: Buffer = try .init(
        device,
        vma,
        u32,
        max_ui_quads * 6,
        c.VK_BUFFER_USAGE_INDEX_BUFFER_BIT,
        .{
            .usage = c.VMA_MEMORY_USAGE_AUTO,
            .flags = c.VMA_ALLOCATION_CREATE_MAPPED_BIT | c.VMA_ALLOCATION_CREATE_HOST_ACCESS_SEQUENTIAL_WRITE_BIT,
        },
    );
    var data: [*]u32 = @ptrCast(@alignCast(ui_index_buffer.info.pMappedData));
    for (0..max_ui_quads) |i| {
        const base: u32 = @as(u32, @intCast(i)) * 4;
        data[i * 6 ..][0..6].* = .{ base, base + 1, base + 2, base + 2, base + 3, base };
    }

    return .{
        .swapchain = swapchain,
        .present_mode = present_mode,
        .images = vk_images,
        .render_semaphores = render_semaphores,
        .image_count = image_count,
        .format = surface_format.format,
        .extent = extent_3d,
        .current_frame_inflight = 0,
        .frames = frames,
        .depth_image = depth_image,
        .draw_image = draw_image,
        .ui_index_buffer = ui_index_buffer,
    };
}

pub fn deinit(
    self: *@This(),
    vma: Vma,
    device: Device,
) void {
    self.draw_image.deinit(vma, device);
    self.depth_image.deinit(vma, device);
    self.ui_index_buffer.deinit(vma);
    for (&self.frames) |*frame| frame.deinit(vma, device);
    for (0..self.image_count) |i| {
        c.vkDestroySemaphore(device.handle, self.render_semaphores[i], null);
    }
    c.vkDestroySwapchainKHR(device.handle, self.swapchain, null);
}

fn create(
    physical_device: PhysicalDevice,
    device: Device,
    surface: Surface,
    chosen_format: c.VkSurfaceFormatKHR,
    present_mode: c.VkPresentModeKHR,
    width: u32,
    height: u32,
) !c.VkSwapchainKHR {
    var swapchain: c.VkSwapchainKHR = undefined;

    var capabilities: c.VkSurfaceCapabilitiesKHR = undefined;
    try check(c.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(physical_device.handle, surface.handle, &capabilities));

    const actual_extent: c.VkExtent2D = try surface.getExtent(physical_device, width, height);

    var swapchain_info: c.VkSwapchainCreateInfoKHR = .{
        .sType = c.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
        .surface = surface.handle,
        .minImageCount = capabilities.minImageCount,
        .imageFormat = chosen_format.format,
        .imageColorSpace = chosen_format.colorSpace,
        .imageExtent = actual_extent,
        .imageArrayLayers = 1,
        .imageUsage = c.VK_IMAGE_USAGE_TRANSFER_DST_BIT,
        .imageSharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
        .preTransform = capabilities.currentTransform,
        .compositeAlpha = c.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
        .presentMode = present_mode,
        .clipped = 1,
    };

    try check(c.vkCreateSwapchainKHR(device.handle, &swapchain_info, null, &swapchain));

    return swapchain;
}

pub fn recreate(
    self: *@This(),
    gpa: std.mem.Allocator,
    vma: Vma,
    physical_device: PhysicalDevice,
    device: Device,
    surface: Surface,
    width: u32,
    height: u32,
) !void {
    try check(c.vkDeviceWaitIdle(device.handle));
    c.vkDestroySwapchainKHR(device.handle, self.swapchain, null);

    const actual_extent = try surface.getExtent(physical_device, width, height);

    const surface_format = try surface.getFormat(gpa, physical_device);
    const swapchain = try create(physical_device, device, surface, surface_format, self.present_mode, actual_extent.width, actual_extent.height);

    self.swapchain = swapchain;

    self.extent = .{ .width = actual_extent.width, .height = actual_extent.height, .depth = 1 };
    var image_count: u32 = undefined;
    try check(c.vkGetSwapchainImagesKHR(device.handle, swapchain, &image_count, null));
    if (image_count > 16) @panic("More than 16 VkImages\n");

    var vk_images: [16]c.VkImage = undefined;
    try check(c.vkGetSwapchainImagesKHR(device.handle, swapchain, &image_count, &vk_images[0]));
    self.images = vk_images;

    self.draw_image.deinit(vma, device);
    self.draw_image = try .init(
        vma,
        device,
        c.VK_FORMAT_R16G16B16A16_SFLOAT,
        self.extent,
        c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT |
            c.VK_IMAGE_USAGE_TRANSFER_DST_BIT |
            c.VK_IMAGE_USAGE_STORAGE_BIT |
            c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
        c.VK_IMAGE_ASPECT_COLOR_BIT,
        false,
    );
    self.depth_image.deinit(vma, device);
    self.depth_image = try .init(
        vma,
        device,
        c.VK_FORMAT_D32_SFLOAT,
        self.extent,
        c.VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT,
        c.VK_IMAGE_ASPECT_DEPTH_BIT,
        false,
    );
}

fn getPresentMode(gpa: std.mem.Allocator, physical_device: PhysicalDevice, surface: Surface) !c.VkPresentModeKHR {
    var present_modes_count: u32 = undefined;
    try check(c.vkGetPhysicalDeviceSurfacePresentModesKHR(physical_device.handle, surface.handle, &present_modes_count, null));
    const present_modes: []c.VkPresentModeKHR = try gpa.alloc(c.VkPresentModeKHR, present_modes_count);
    defer gpa.free(present_modes);
    try check(c.vkGetPhysicalDeviceSurfacePresentModesKHR(physical_device.handle, surface.handle, &present_modes_count, present_modes.ptr));

    var found_present_mode: u32 = c.VK_PRESENT_MODE_FIFO_KHR;

    for (present_modes) |mode| {
        if (mode == c.VK_PRESENT_MODE_MAILBOX_KHR) {
            found_present_mode = mode;
            break;
        }

        if (mode == c.VK_PRESENT_MODE_IMMEDIATE_KHR) {
            found_present_mode = mode;
        } else if (mode == c.VK_PRESENT_MODE_FIFO_RELAXED_KHR and found_present_mode == c.VK_PRESENT_MODE_FIFO_KHR) {
            found_present_mode = mode;
        }
    }
    return found_present_mode;
}

pub const FrameData = struct {
    pub const UiVertex = extern struct {
        position: [2]f32,
        uv: [2]f32,
        color: [4]f32,
    };

    swapchain_semaphore: c.VkSemaphore,
    render_fence: c.VkFence,
    command_buffer: c.VkCommandBuffer,
    gpu_scene: Buffer,
    ui_vertex_buffer: Buffer,

    pub const GPUScene = extern struct {
        view_proj: [16]f32,
        global_light_direction: [3]f32,
        time: f32,
    };

    pub fn init(vma: Vma, device: Device) !@This() {
        var alloc_info: c.VkCommandBufferAllocateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .commandPool = device.command_pool.handle,
            .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1,
        };

        var command_buffer: c.VkCommandBuffer = undefined;
        try check(c.vkAllocateCommandBuffers(device.handle, &alloc_info, &command_buffer));

        var semaphoreCreateInfo: c.VkSemaphoreCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
        };
        var swapchain_semaphore: c.VkSemaphore = undefined;
        try check(c.vkCreateSemaphore(device.handle, &semaphoreCreateInfo, null, &swapchain_semaphore));

        var fence_info: c.VkFenceCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
            .flags = c.VK_FENCE_CREATE_SIGNALED_BIT,
        };

        var render_fence: c.VkFence = undefined;
        try check(c.vkCreateFence(device.handle, &fence_info, null, &render_fence));

        return .{
            .command_buffer = command_buffer,
            .swapchain_semaphore = swapchain_semaphore,
            .render_fence = render_fence,
            .gpu_scene = try .init(
                device,
                vma,
                GPUScene,
                1,
                c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT | c.VK_BUFFER_USAGE_2_RESOURCE_DESCRIPTOR_BUFFER_BIT_EXT | c.VK_BUFFER_USAGE_2_SHADER_DEVICE_ADDRESS_BIT,
                .{
                    .usage = Vma.c.VMA_MEMORY_USAGE_CPU_TO_GPU,
                    .flags = Vma.c.VMA_ALLOCATION_CREATE_MAPPED_BIT,
                },
            ),
            .ui_vertex_buffer = try .init(
                device,
                vma,
                UiVertex,
                max_ui_quads * 4,
                c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | c.VK_BUFFER_USAGE_2_SHADER_DEVICE_ADDRESS_BIT,
                .{
                    .usage = Vma.c.VMA_MEMORY_USAGE_CPU_TO_GPU,
                    .flags = Vma.c.VMA_ALLOCATION_CREATE_MAPPED_BIT,
                },
            ),
        };
    }

    pub fn deinit(self: *@This(), vma: Vma, device: Device) void {
        c.vkDestroySemaphore(device.handle, self.swapchain_semaphore, null);
        c.vkDestroyFence(device.handle, self.render_fence, null);
        c.vkFreeCommandBuffers(device.handle, device.command_pool.handle, 1, &self.command_buffer);
        self.gpu_scene.deinit(vma);
        self.ui_vertex_buffer.deinit(vma);
    }
};
