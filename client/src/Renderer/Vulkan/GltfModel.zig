const std = @import("std");
const c = @import("vulkan");
const zgltf = @import("zgltf");
const Vma = @import("Vma.zig");
const AssetServer = @import("shared").AssetServer;
const Device = @import("device.zig").Logical;
const Image = @import("Image.zig");
const Mesh = @import("Mesh.zig");
const Node = @import("Node.zig");
const Material = @import("Material.zig");
const ext = @import("procs.zig").device.ProcTable;
pub const check = @import("utils.zig").check;

device: Device,
vma: Vma,
model_name: []const u8,
mesh: ?Mesh = null,
// default_image: Image,
// material_data_buffer: vk.Buffer = undefined,
// storage for all the data on a given glTF file
// meshes: std.StringHashMapUnmanaged(*Mesh) = .empty,
// nodes: std.StringHashMapUnmanaged(*Node) = .empty,
// images: std.StringHashMapUnmanaged(*Image) = .empty,
// materials: std.StringHashMapUnmanaged(*Material.Instance) = .empty,
// nodes that dont have a parent, for iterating through the file in tree order
// top_nodes: std.ArrayList(*Node) = .empty,
// samplers: std.ArrayList(c.VkSampler) = .empty,

pub fn init(gpa: std.mem.Allocator, vma: Vma, device: Device, asset_server: *AssetServer, model_name: []const u8) !*@This() {
    const self = try gpa.create(@This());
    self.* = .{
        .vma = vma,
        .device = device,
        .model_name = model_name,
    };
    try asset_server.loadAsset(@This(), self, model_name, loadModel);
    return self;
}
pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
    // ext.vkDestroyShaderEXT(self.device.handle, self.handle, null);
    if (self.mesh) |*mesh| mesh.deinit(gpa, self.vma);
    self.* = undefined;
    gpa.destroy(self);
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
            surfaces.appendAssumeCapacity(.{ .index_count = indices_count, .index_start = indices_start });
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
