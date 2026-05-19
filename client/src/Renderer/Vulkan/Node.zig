const std = @import("std");
const vk = @import("vulkan");
const nz = @import("numz");
const Mesh = @import("Mesh.zig");
const Material = @import("Material.zig");

parent: ?*@This() = null,
mesh: ?*Mesh = null,
material: *const Material.Instance = undefined,
children: std.ArrayList(*@This()) = .empty,
local_transform: nz.Transform3D(f32) = undefined,
world_transform: nz.Transform3D(f32) = undefined,

pub fn refreshTransform(self: *@This(), parent_transform: *nz.Transform3D(f32)) void {
    self.world_transform = nz.Transform3D(f32).fromMat4x4(parent_transform.toMat4x4().mul(self.local_transform.toMat4x4()));
    for (self.children.items[0..self.children.items.len]) |child| {
        child.refreshTransform(&self.world_transform);
    }
}

pub fn draw(self: *@This(), allocator: std.mem.Allocator, top_transform: nz.Transform3D(f32), ctx: *DrawContext) !void {
    const node_transform: nz.Transform3D(f32) = .fromMat4x4(top_transform.toMat4x4().mul(self.world_transform.toMat4x4()));
    if (self.mesh) |mesh| {
        for (mesh.surfaces.items[0..mesh.surfaces.items.len]) |surface| {
            const render_obj: RenderObject = .{
                .index_count = @intCast(surface.index_count),
                .first_index = @intCast(surface.index_start),
                .index_buffer = mesh.index_buffer.buffer,
                .material_instance = surface.material,
                .transform = node_transform,
                .vertex_buffer_address = mesh.vertex_buffer_address,
                .bounds = surface.bounds,
            };
            if (surface.material.pass_type == .transparent) {
                try ctx.transparent_surfaces.append(allocator, render_obj);
            } else {
                try ctx.opaque_surfaces.append(allocator, render_obj);
            }
        }
    }

    for (self.children.items) |*child| {
        try child.*.draw(allocator, top_transform, ctx);
    }
}

pub const RenderObject = struct {
    index_count: u32,
    first_index: u32,
    index_buffer: vk.VkBuffer,

    material_instance: *const Material.Instance,
    bounds: Mesh.Bounds,
    transform: nz.Transform3D(f32),
    vertex_buffer_address: vk.VkDeviceAddress,

    pub fn isVisible(self: *const @This(), view_proj: nz.Mat4x4(f32)) bool {
        const corners: []const nz.Vec3(f32) = &.{
            .{ 1, 1, 1 },
            .{ 1, 1, -1 },
            .{ 1, -1, 1 },
            .{ 1, -1, -1 },
            .{ -1, 1, 1 },
            .{ -1, 1, -1 },
            .{ -1, -1, 1 },
            .{ -1, -1, -1 },
        };

        var matrix = view_proj.mul(self.transform.toMat4x4());

        var min: nz.Vec3(f32) = .{ 1.5, 1.5, 1.5 };
        var max: nz.Vec3(f32) = .{ -1.5, -1.5, -1.5 };

        for (corners) |corner| {
            // project each corner into clip space
            const tmp: nz.Vec3(f32) = (self.bounds.origin + (corner * self.bounds.extents));
            var v: nz.Vec4(f32) = matrix.mulVec4(.{ tmp[0], tmp[1], tmp[2], 1 });

            // perspective correction
            v[0] = v[0] / v[3];
            v[1] = v[1] / v[3];
            v[2] = v[2] / v[3];

            min = @min(@as(nz.Vec3(f32), .{ v[0], v[1], v[2] }), min);
            max = @max(@as(nz.Vec3(f32), .{ v[0], v[1], v[2] }), max);
        }

        // check the clip space box is within the view
        return !(min[2] > 1 or max[2] < 0 or min[0] > 1 or max[0] < -1 or min[1] > 1 or max[1] < -1);
    }
};

pub const DrawContext = struct {
    opaque_surfaces: std.ArrayList(RenderObject) = .empty,
    transparent_surfaces: std.ArrayList(RenderObject) = .empty,

    pub fn clear(self: *@This()) void {
        self.opaque_surfaces.clearRetainingCapacity();
        self.transparent_surfaces.clearRetainingCapacity();
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.opaque_surfaces.deinit(allocator);
        self.transparent_surfaces.deinit(allocator);
    }
};
