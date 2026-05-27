const std = @import("std");
const c = @import("vulkan");
const nz = @import("shared").numz;
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
const RenderResources = @import("../Vulkan.zig").RenderResources;
pub const check = @import("utils.zig").check;

device: Device,
vma: Vma,
model_name: []const u8,
render_resources: *RenderResources,

nodes: std.ArrayList(Node) = .empty,
top_nodes: std.ArrayList(*Node) = .empty,
pub fn init(
    gpa: std.mem.Allocator,
    vma: Vma,
    device: Device,
    asset_server: *AssetServer,
    model_name: []const u8,
    render_resources: *RenderResources,
) !*@This() {
    const self = try gpa.create(@This());
    self.* = .{
        .vma = vma,
        .device = device,
        .model_name = model_name,
        .render_resources = render_resources,
        .nodes = .empty,
        .top_nodes = .empty,
    };
    try asset_server.loadAsset(@This(), self, model_name, loadModel);
    return self;
}
// pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
//     // ext.vkDestroyShaderEXT(self.device.handle, self.handle, null);
//     self.clear(gpa);
//     self.samplers.deinit(gpa);
//     self.images.deinit(gpa);
//     self.buffers.deinit(gpa);
//     if (self.mesh) |*mesh| mesh.deinit(gpa, self.vma);
//     self.* = undefined;
//     gpa.destroy(self);
// }

// fn clear(self: *@This(), gpa: std.mem.Allocator) void {
//     _ = gpa;
//     for (self.samplers.items) |sampler| {
//         c.vkDestroySampler(self.device.handle, sampler, null);
//     }
//     self.samplers.clearRetainingCapacity();
//
//     for (self.images.items) |*image| {
//         image.deinit(self.vma, self.device);
//     }
//     self.images.clearRetainingCapacity();
//
//     for (self.buffers.items) |*buffer| {
//         buffer.deinit(self.vma);
//     }
//     self.buffers.clearRetainingCapacity();
// }

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
    const gltf_loaded = loaded.parsed.value;
    const bin = loaded.bin orelse return error.MissingBin;

    // self.clear(gpa);

    const original_sample_count = self.render_resources.samplers.items.len;
    if (gltf_loaded.samplers) |samplers| {
        std.log.info("Sampler count was {d}", .{samplers.len});
        for (samplers) |sampler| {
            const sampler_info: c.VkSamplerCreateInfo = .{
                .sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
                .maxLod = c.VK_LOD_CLAMP_NONE,
                .minLod = 0,
                .magFilter = if (sampler.magFilter) |filter| switch (filter) {
                    .nearest => c.VK_FILTER_NEAREST,
                    .linear => c.VK_FILTER_LINEAR,
                } else c.VK_FILTER_LINEAR,
                .minFilter = if (sampler.minFilter) |filter| switch (filter) {
                    .nearest => c.VK_FILTER_NEAREST,
                    .linear => c.VK_FILTER_LINEAR,
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
            //TODO: map sampler when getting more meshes.
            try self.render_resources.samplers.append(gpa, new_sampler);
        }
    } else {
        std.log.info("Sampler count was 0", .{});
    }

    // var images: std.ArrayList(Image) = .empty;
    // defer images.deinit(gpa);
    const original_image_count = self.render_resources.images.items.len;
    if (gltf_loaded.images) |images| {
        std.log.info("image count was {d}", .{images.len});
        for (images) |image| {
            if (image.uri == null and image.bufferView == null) return error.FailedToLoadGLTFImage;
            var pixels: [*c]stb.stbi_uc = null;
            var width: i32, var height: i32, var nr_channel: i32 = .{ 0, 0, 0 };
            if (image.uri) |uri| {
                try if (std.mem.eql(u8, "data:", uri[0..5])) error.DataNotsupported;
                const c_uri = try gpa.dupeSentinel(u8, uri, 0);
                defer gpa.free(c_uri);
                pixels = stb.stbi_load(c_uri, &width, &height, &nr_channel, 4);
            } else if (image.bufferView) |buffer_view_index| {
                const buffer_view = gltf_loaded.bufferViews.?[buffer_view_index];
                const bytes_offset = buffer_view.byteOffset;
                const byte_len = buffer_view.byteLength;
                const bytes = bin[bytes_offset .. bytes_offset + byte_len];
                pixels = stb.stbi_load_from_memory(bytes.ptr, @intCast(bytes.len), &width, &height, &nr_channel, 4);
            }
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
            try self.render_resources.images.append(gpa, new_image);
        }
    } else {
        std.log.info("image count was 0", .{});
    }

    if (gltf_loaded.meshes) |meshes| for (meshes) |mesh| {
        var surfaces: std.ArrayList(Mesh.GeoSurface) = try .initCapacity(gpa, mesh.primitives.len);
        defer surfaces.deinit(gpa);
        var vertices: std.ArrayList(Mesh.Vertex) = .empty;
        defer vertices.deinit(gpa);
        var indices: std.ArrayList(u32) = .empty;
        defer indices.deinit(gpa);

        std.log.debug("MESH primitives: {d}\n", .{mesh.primitives.len});
        for (mesh.primitives) |primitive| {
            var indices_start: u32 = 0;
            var indices_count: u32 = 0;
            {
                indices_start = @intCast(indices.items.len);

                const acc_idx = primitive.indices.?;
                var acc = gltf_loaded.accessors.?[acc_idx];
                const bv = gltf_loaded.bufferViews.?[acc.bufferView.?];
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

            const pos_accessor_idx = primitive.attributes.map.get("POSITION") orelse return error.NoPosition;
            const pos_accessor = gltf_loaded.accessors.?[pos_accessor_idx];
            const buffer_view = gltf_loaded.bufferViews.?[pos_accessor.bufferView.?];
            const offset = (pos_accessor.byteOffset + buffer_view.byteOffset);
            std.debug.assert(pos_accessor.componentType == @intFromEnum(zgltf.ComponentType.float));
            const positions = std.mem.bytesAsSlice(
                [3]f32,
                bin[offset .. offset + pos_accessor.count * @sizeOf([3]f32)],
            );

            const material_index = primitive.material.?;
            const material = gltf_loaded.materials.?[material_index];
            // std.log.debug("MATERIAL : {any}", .{material});
            var material_name: ?[]const u8 = null;
            if (material.pbrMetallicRoughness.?.baseColorTexture) |basecolor| {
                if (material.name != null and self.render_resources.materials.contains(material.name.?)) {
                    material_name = (try self.render_resources.getMaterialPtr(material.name.?)).name;
                } else {
                    const texture_index = basecolor.index;

                    const texture_info = gltf_loaded.textures.?[texture_index];
                    const image_index = texture_info.source.?;
                    const sampler_index = texture_info.sampler.?;

                    const new_material: Material = try .init(
                        gpa,
                        material.name.?,
                        self.device,
                        self.vma,
                        self.render_resources.set_size,
                        self.render_resources.combined_image_sampler_descriptor_size,
                        self.render_resources.samplers.items[original_sample_count + sampler_index],
                        self.render_resources.images.items[original_image_count + image_index].vk_imageview,
                    );
                    try self.render_resources.createMaterial(gpa, new_material);
                    material_name = new_material.name;
                }
            }
            surfaces.appendAssumeCapacity(.{
                .index_count = indices_count,
                .index_start = indices_start,
                .material_name = if (material_name) |name| name else RenderResources.default_material_name,
            });

            const uv_accessor_idx = primitive.attributes.map.get("TEXCOORD_0") orelse return error.NoUV;
            const uv_accessor = gltf_loaded.accessors.?[uv_accessor_idx];
            std.debug.assert(uv_accessor.componentType == @intFromEnum(zgltf.ComponentType.float));
            const uv_buffer_view = gltf_loaded.bufferViews.?[uv_accessor.bufferView.?];
            const uv_offset = (uv_accessor.byteOffset + uv_buffer_view.byteOffset);
            const uvs = std.mem.bytesAsSlice(
                [2]f32,
                bin[uv_offset .. uv_offset + uv_accessor.count * @sizeOf([2]f32)],
            );

            const normal_accessor_idx = primitive.attributes.map.get("NORMAL") orelse return error.NoNormal;
            const normal_accessor = gltf_loaded.accessors.?[normal_accessor_idx];
            std.debug.assert(normal_accessor.componentType == @intFromEnum(zgltf.ComponentType.float));
            const normal_buffer_view = gltf_loaded.bufferViews.?[normal_accessor.bufferView.?];
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
        }

        if (mesh.name != null and !self.render_resources.meshes.contains(mesh.name.?)) {
            const new_mesh: Mesh = try .init(
                gpa,
                self.vma,
                mesh.name.?,
                self.device,
                Mesh.Vertex,
                vertices.items,
                indices.items,
                surfaces.items,
            );
            try self.render_resources.createMesh(gpa, new_mesh);
        }
    };

    if (gltf_loaded.nodes) |nodes| {
        _ = try self.nodes.addManyAsSlice(gpa, nodes.len);
        for (nodes, self.nodes.items) |gltf_node, *scene_node| {
            scene_node.* = .{};
            if (gltf_node.mesh) |mesh_id| {
                const gltf_mesh = gltf_loaded.meshes.?[mesh_id];
                // std.log.debug("try load mesh name: {s}", .{gltf_mesh.name.?});
                const mesh = try self.render_resources.getMeshPtr(gltf_mesh.name);
                // std.log.debug("laoded mesh name: {s}", .{mesh.name});
                scene_node.mesh_id = mesh.name;
            }

            if (gltf_node.matrix) |matrix| {
                const local_matrix: nz.Mat4x4(f32) = .{ .d = matrix };
                scene_node.local_transform = .fromMat4x4(local_matrix);
            } else {
                const tl = if (gltf_node.translation) |translation| nz.Mat4x4(f32).translate(translation) else nz.Mat4x4(f32).identity;
                const rot = if (gltf_node.rotation) |rotation| nz.quat.Hamiltonian(f32).fromVec(rotation).toMat4x4() else nz.quat.Hamiltonian(f32).identity.toMat4x4();
                const scale = if (gltf_node.scale) |scale| nz.Mat4x4(f32).scale(scale) else nz.Mat4x4(f32).identity;
                scene_node.local_transform = .fromMat4x4(scale.mul(rot).mul(tl));
            }
            // std.log.debug("gltfdata {any}", .{gltf_node});
            // std.log.debug("\n\n\nOWN {any}", .{scene_node});
            // std.log.debug("\nNODE PTR: {*}", .{scene_node});

            if (gltf_node.children) |children| {
                for (children) |child_id| {
                    try scene_node.children.append(gpa, &self.nodes.items[child_id]);
                    self.nodes.items[child_id].parent = scene_node;
                }
            }

            //TODO: do this when lib is ready.
            // if (gltf_node.parent == null) {
            //     try self.top_nodes.append(gpa, scene_node);
            //     var top_transform: nz.Transform3D(f32) = .{};
            //     gltf_node.refreshTransform(&top_transform);
            // }
        }
    }
    for (self.nodes.items) |*node| {
        if (node.parent == null) {
            try self.top_nodes.append(gpa, node);
            var top_transform: nz.Transform3D(f32) = .{};
            node.refreshTransform(&top_transform);
            // std.log.debug("\n\n\nPARENT {any}", .{node});
        }
    }
}
