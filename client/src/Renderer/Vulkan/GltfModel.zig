const std = @import("std");
const c = @import("vulkan");
const zgltf = @import("zgltf");
const stb = @import("stb");
const Vma = @import("Vma.zig");
const AssetServer = @import("shared").AssetServer;
const Device = @import("device.zig").Logical;
const Image = @import("Image.zig");
const Mesh = @import("Mesh.zig");
const Node = @import("Node.zig");
const Material = @import("Material.zig");
const Buffer = @import("Buffer.zig");
const ext = @import("procs.zig").device.ProcTable;
pub const check = @import("utils.zig").check;

device: Device,
vma: Vma,
model_name: []const u8,
mesh: ?Mesh = null,
set_size: c.VkDeviceSize,
binding_offser: c.VkDeviceSize,
combinedImageSamplerDescriptorSize: usize,
// default_image: Image,
// material_data_buffer: vk.Buffer = undefined,
// storage for all the data on a given glTF file
// meshes: std.StringHashMapUnmanaged(*Mesh) = .empty,
// nodes: std.StringHashMapUnmanaged(*Node) = .empty,
// materials: std.StringHashMapUnmanaged(*Material.Instance) = .empty,
// nodes that dont have a parent, for iterating through the file in tree order
// top_nodes: std.ArrayList(*Node) = .empty,
images: std.ArrayList(Image) = .empty,
samplers: std.ArrayList(c.VkSampler) = .empty,
buffers: std.ArrayList(Buffer) = .empty,

pub fn init(
    gpa: std.mem.Allocator,
    vma: Vma,
    device: Device,
    asset_server: *AssetServer,
    model_name: []const u8,
    set_size: c.VkDeviceSize,
    binding_offser: c.VkDeviceSize,
    combinedImageSamplerDescriptorSize: usize,
) !*@This() {
    const self = try gpa.create(@This());
    self.* = .{
        .vma = vma,
        .device = device,
        .model_name = model_name,
        .combinedImageSamplerDescriptorSize = combinedImageSamplerDescriptorSize,
        .set_size = set_size,
        .binding_offser = binding_offser,
    };
    try asset_server.loadAsset(@This(), self, model_name, loadModel);
    return self;
}
pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
    // ext.vkDestroyShaderEXT(self.device.handle, self.handle, null);
    self.clear(gpa);
    self.samplers.deinit(gpa);
    self.images.deinit(gpa);
    self.buffers.deinit(gpa);
    if (self.mesh) |*mesh| mesh.deinit(gpa, self.vma);
    self.* = undefined;
    gpa.destroy(self);
}

fn clear(self: *@This(), gpa: std.mem.Allocator) void {
    _ = gpa;
    for (self.samplers.items) |sampler| {
        c.vkDestroySampler(self.device.handle, sampler, null);
    }
    self.samplers.clearRetainingCapacity();

    for (self.images.items) |*image| {
        image.deinit(self.vma, self.device);
    }
    self.images.clearRetainingCapacity();

    for (self.buffers.items) |*buffer| {
        buffer.deinit(self.vma);
    }
    self.buffers.clearRetainingCapacity();
}

fn loadModel(user_data: *anyopaque, gpa: std.mem.Allocator, io: std.Io, file: std.Io.File, file_path: []const u8) !void {
    _ = file_path;
    const self: *@This() = @ptrCast(@alignCast(user_data));
    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    const content = try reader.interface.allocRemaining(gpa, .unlimited);
    defer gpa.free(content);
    std.debug.print("size:  {d}\n", .{content.len});

    var loaded = try zgltf.parseGlbSlice(gpa, content);
    defer loaded.deinit();
    const g = loaded.parsed.value;
    const bin = loaded.bin orelse return error.MissingBin;

    self.clear(gpa);

    if (g.samplers) |samplers| {
        std.log.info("Sampler count was {d}", .{samplers.len});
        for (samplers) |sampler| {
            const sampler_info: c.VkSamplerCreateInfo = .{
                .sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
                .maxLod = c.VK_LOD_CLAMP_NONE,
                .minLod = 0,
                .magFilter = if (sampler.magFilter) |filter| switch (filter) {
                    9728 => c.VK_FILTER_NEAREST,
                    9729 => c.VK_FILTER_LINEAR,
                    else => c.VK_FILTER_LINEAR,
                } else c.VK_FILTER_LINEAR,
                .minFilter = if (sampler.minFilter) |filter| switch (filter) {
                    9728 => c.VK_FILTER_NEAREST,
                    9729 => c.VK_FILTER_LINEAR,
                    else => c.VK_FILTER_LINEAR,
                } else c.VK_FILTER_LINEAR,
                .mipmapMode = c.VK_SAMPLER_MIPMAP_MODE_NEAREST,
                .addressModeU = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER,
                .addressModeV = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER,
                .addressModeW = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER,
                .anisotropyEnable = c.VK_FALSE,
                .borderColor = c.VK_BORDER_COLOR_INT_OPAQUE_BLACK,
                .unnormalizedCoordinates = c.VK_FALSE,
                .compareEnable = c.VK_FALSE,
                .compareOp = c.VK_COMPARE_OP_ALWAYS,
            };
            var new_sampler: c.VkSampler = undefined;
            try check(c.vkCreateSampler(self.device.handle, &sampler_info, null, &new_sampler));
            try self.samplers.append(gpa, new_sampler);
        }
    } else {
        std.log.info("Sampler count was 0", .{});
    }

    // var images: std.ArrayList(Image) = .empty;
    // defer images.deinit(gpa);
    if (g.images) |images| {
        std.log.info("image count was {d}", .{images.len});
        for (images) |image| {
            if (image.uri) |uri| {
                try if (std.mem.eql(u8, "data:", uri[0..5])) error.DataNotsupported;
                var width: i32, var height: i32, var nr_channel: i32 = .{ 0, 0, 0 };
                const c_uri = try gpa.dupeSentinel(u8, uri, 0);
                defer gpa.free(c_uri);
                const pixels = stb.stbi_load(c_uri, &width, &height, &nr_channel, 4);
                defer stb.stbi_image_free(pixels);
                try if (pixels == null) error.LoadingStbi;

                var new_image: Image = try .init(
                    self.vma,
                    self.device,
                    c.VK_FORMAT_R8G8B8A8_UNORM,
                    .{ .width = @intCast(width), .height = @intCast(height), .depth = 1 },
                    c.VK_IMAGE_USAGE_SAMPLED_BIT | c.VK_IMAGE_USAGE_TRANSFER_DST_BIT | c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
                    c.VK_IMAGE_ASPECT_COLOR_BIT,
                    true,
                );
                try new_image.uploadDataToImage(self.vma, self.device, pixels);
                try self.images.append(gpa, new_image);
            } else {
                std.log.debug("look: {any}", .{image.uri});
                // @panic("not implemented NO URI for image");
            }
        }
    } else {
        std.log.info("image count was 0", .{});
    }

    if (self.mesh) |*mesh| mesh.deinit(gpa, self.vma);
    if (g.meshes) |meshes| for (meshes) |mesh| {
        var surfaces: std.ArrayList(Mesh.GeoSurface) = try .initCapacity(gpa, mesh.primitives.len);
        defer surfaces.deinit(gpa);
        var vertices: std.ArrayList(Mesh.Vertex) = .empty;
        defer vertices.deinit(gpa);
        var indices: std.ArrayList(u32) = .empty;
        defer indices.deinit(gpa);

        std.log.debug("MESH primitives: {d}\n", .{mesh.primitives.len});
        for (mesh.primitives) |p| {
            var indices_start: u32 = 0;
            var indices_count: u32 = 0;
            {
                indices_start = @intCast(indices.items.len);

                const acc_idx = p.indices.?;
                var acc = g.accessors.?[acc_idx];
                const bv = g.bufferViews.?[acc.bufferView.?];
                const offset = bv.byteOffset + acc.byteOffset;

                const element_size = try acc.elementSize();
                const amount_of_bytes = acc.count * element_size;
                const bytes = bin[offset .. offset + amount_of_bytes];

                const dst = try indices.addManyAsSlice(gpa, acc.count);
                for (0..acc.count) |i| {
                    const off = i * element_size;
                    dst[i] = switch (element_size) {
                        1 => bytes[off],
                        2 => std.mem.readInt(u16, bytes[off..][0..2], .little),
                        4 => std.mem.readInt(u32, bytes[off..][0..4], .little),
                        else => return error.BadIndexSize,
                    };
                    dst[i] += @intCast(vertices.items.len);
                }
                indices_count = @intCast(acc.count);
            }

            const pos_accessor_idx = p.attributes.map.get("POSITION") orelse return error.NoPosition;
            const pos_accessor = g.accessors.?[pos_accessor_idx];
            const buffer_view = g.bufferViews.?[pos_accessor.bufferView.?];
            const offset = (pos_accessor.byteOffset + buffer_view.byteOffset);
            std.debug.assert(pos_accessor.componentType == @intFromEnum(zgltf.ComponentType.float));
            const positions = std.mem.bytesAsSlice(
                [3]f32,
                bin[offset .. offset + pos_accessor.count * @sizeOf([3]f32)],
            );

            //TODO: Material
            const material_index = p.material.?;
            std.log.debug("maertial idx {d}", .{material_index});
            const material = g.materials.?[material_index];
            std.log.debug("material: {any}", .{material});
            const texture_index = material.pbrMetallicRoughness.?.baseColorTexture.?.index;
            const texture_info = g.textures.?[texture_index];
            const image_index = texture_info.source.?;
            const sampler_index = texture_info.sampler.?;

            // create a buffer sized to one descriptor set
            const new_desc_buf = try Buffer.init(
                self.device,
                self.vma,
                u8,
                self.set_size,
                c.VK_BUFFER_USAGE_RESOURCE_DESCRIPTOR_BUFFER_BIT_EXT |
                    c.VK_BUFFER_USAGE_SAMPLER_DESCRIPTOR_BUFFER_BIT_EXT | c.VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT,
                .{ .usage = Vma.c.VMA_MEMORY_USAGE_CPU_TO_GPU, .flags = Vma.c.VMA_ALLOCATION_CREATE_MAPPED_BIT },
            );

            // write the descriptor at offset 0
            const img_info: c.VkDescriptorImageInfo = .{
                .sampler = self.samplers.items[sampler_index],
                .imageView = self.images.items[image_index].vk_imageview,
                .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            };
            const get_info: c.VkDescriptorGetInfoEXT = .{
                .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_GET_INFO_EXT,
                .type = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                .data = .{ .pCombinedImageSampler = &img_info },
            };
            const material_dst: [*]u8 = @ptrCast(new_desc_buf.info.pMappedData);
            ext.vkGetDescriptorEXT(self.device.handle, &get_info, self.combinedImageSamplerDescriptorSize, material_dst);
            try self.buffers.append(gpa, new_desc_buf);

            const uv_accessor_idx = p.attributes.map.get("TEXCOORD_0") orelse return error.NoUV;
            const uv_accessor = g.accessors.?[uv_accessor_idx];
            std.debug.assert(uv_accessor.componentType == @intFromEnum(zgltf.ComponentType.float));
            const uv_buffer_view = g.bufferViews.?[uv_accessor.bufferView.?];
            const uv_offset = (uv_accessor.byteOffset + uv_buffer_view.byteOffset);
            const uvs = std.mem.bytesAsSlice(
                [2]f32,
                bin[uv_offset .. uv_offset + uv_accessor.count * @sizeOf([2]f32)],
            );

            const normal_accessor_idx = p.attributes.map.get("NORMAL") orelse return error.NoNormal;
            const normal_accessor = g.accessors.?[normal_accessor_idx];
            std.debug.assert(normal_accessor.componentType == @intFromEnum(zgltf.ComponentType.float));
            const normal_buffer_view = g.bufferViews.?[normal_accessor.bufferView.?];
            const normal_offset = (normal_accessor.byteOffset + normal_buffer_view.byteOffset);
            const normals = std.mem.bytesAsSlice(
                [3]f32,
                bin[normal_offset .. normal_offset + normal_accessor.count * @sizeOf([3]f32)],
            );

            var dst = try vertices.addManyAsSlice(gpa, pos_accessor.count);
            for (0..pos_accessor.count) |i| {
                dst[i] = .{
                    .color = .{ 1, 0, 0, 1 },
                    .normal = normals[i],
                    .position = positions[i],
                    .uv_x = uvs[i][0],
                    .uv_y = uvs[i][1],
                };
            }
            surfaces.appendAssumeCapacity(.{ .index_count = indices_count, .index_start = indices_start, .material_index = @intCast(self.buffers.items.len - 1) });
        }
        self.mesh = try .init(
            gpa,
            self.vma,
            mesh.name orelse "dummy_name",
            self.device,
            Mesh.Vertex,
            vertices.items,
            indices.items,
            surfaces.items,
        );
    };
}
