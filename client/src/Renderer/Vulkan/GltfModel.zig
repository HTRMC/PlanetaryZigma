const std = @import("std");
const c = @import("vulkan");
const zgltf = @import("zgltf");
const AssetServer = @import("shared").AssetServer;
const Device = @import("device.zig").Logical;
const Image = @import("Image.zig");
const Mesh = @import("Mesh.zig");
const Node = @import("Node.zig");
const Material = @import("Material.zig");
const ext = @import("procs.zig").device.ProcTable;
pub const check = @import("utils.zig").check;

device: Device,
model_name: []const u8,
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

pub fn init(gpa: std.mem.Allocator, device: Device, asset_server: *AssetServer, model_name: []const u8) !*@This() {
    const self = try gpa.create(@This());
    self.* = .{
        .device = device,
        .model_name = model_name,
    };
    try asset_server.loadAsset(@This(), self, model_name, loadModel);
    return self;
}
pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
    // ext.vkDestroyShaderEXT(self.device.handle, self.handle, null);
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
    _ = self;

    var loaded = try zgltf.parseGlbSlice(gpa, content);
    defer loaded.deinit();
    const g = loaded.parsed.value;
    const bin = loaded.bin orelse return error.MissingBin;

    // std.log.debug("version: {s}\n", .{g.asset.version});
    if (g.asset.generator) |gen| std.log.debug("generator: {s}\n", .{gen});
    if (g.buffers) |bs| std.log.debug("buffers: {d}\n", .{bs.len});
    if (g.bufferViews) |vs| std.log.debug("bufferViews: {d}\n", .{vs.len});
    if (g.accessors) |as| {
        std.log.debug("accessors: {d}\n", .{as.len});

        for (as, 0..) |a, i| {
            const ct: zgltf.ComponentType = @enumFromInt(a.componentType);
            std.log.debug("  [{d}] type={t} componentType={t} count={d} bytes={d}\n", .{
                i, a.type, ct, a.count, ct.byteSize() * a.type.componentCount() * a.count,
            });
        }
    }
    if (g.meshes) |meshes| for (meshes) |mesh| {
        std.log.debug("primitives: {d}\n", .{mesh.primitives.len});
        for (mesh.primitives) |p| {
            const pos_accessor_idx = p.attributes.map.get("POSITION") orelse return error.NoPosition;
            const pos_accessor = g.accessors.?[pos_accessor_idx];
            std.log.debug("primitive-pos: {d}\n", .{pos_accessor_idx});
            const ct: zgltf.ComponentType = @enumFromInt(pos_accessor.componentType);
            std.log.debug("  type={t} componentType={t} count={d} bytes={d}\n", .{
                pos_accessor.type, ct, pos_accessor.count, ct.byteSize() * pos_accessor.type.componentCount() * pos_accessor.count,
            });
            const buffer_view = g.bufferViews.?[pos_accessor.bufferView.?];
            // const buffer = g.buffers.?[buffer_view.buffer];
            const offset = (pos_accessor.byteOffset + buffer_view.byteOffset);
            const positions = std.mem.bytesAsSlice(
                [3]f32,
                bin[offset .. offset + pos_accessor.count * @sizeOf([3]f32)],
            );
            for (positions) |v| {
                std.log.debug("vertex: {any}", .{v});
            }
            // if (p.targets) |t| {
            //     for (t) |tar|{
            //     }
            // }
            std.log.debug("primitive-attributes: {any}\n", .{p.attributes});
            // if (p.indices) |ind| std.log.debug("indices: {d}\n", .{ind});
        }
    };
}
