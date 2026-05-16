const std = @import("std");
const shared = @import("shared");
const c = @import("vulkan");
const nz = @import("shared").numz;
const Device = @import("device.zig").Logical;
const Buffer = @import("Buffer.zig");
const Vma = @import("Vma.zig");

pub const Planet = @import("Meshes/Planet.zig");
pub const box = @import("Meshes/box.zig");

// surfaces: std.ArrayList(GeoSurface),
index_buffer: Buffer,
vertex_buffer: Buffer,
name: []const u8,

pub const Vertex = shared.Planet.RenderVertex;
// pub const Bounds = struct {
//     origin: nz.Vec3(f32),
//     sphere_radius: f32,
//     extents: nz.Vec3(f32),
// };
//
// pub const GeoSurface = struct {
//     index_start: i32,
//     index_count: i32,
//     bounds: Bounds,
//     material: *const Material.Instance,
// };
//
pub fn init(
    gpa: std.mem.Allocator,
    vma: Vma,
    name: []const u8,
    device: Device,
    // geo_surfaces: []const GeoSurface,
    indices: []const u32,
    vertex_type: type,
    vertices: []const vertex_type,
) !@This() {
    var vertex_buffer: Buffer = try .init(
        device,
        vma,
        vertex_type,
        vertices.len,
        c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | c.VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT_KHR,
        .{
            .usage = c.VMA_MEMORY_USAGE_AUTO,
            .flags = c.VMA_ALLOCATION_CREATE_MAPPED_BIT | c.VMA_ALLOCATION_CREATE_HOST_ACCESS_SEQUENTIAL_WRITE_BIT,
        },
    );
    vertex_buffer.copy(vertex_type, vertices);

    var index_buffer: Buffer = try .init(
        device,
        vma,
        u32,
        indices.len,
        c.VK_BUFFER_USAGE_INDEX_BUFFER_BIT | c.VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT_KHR,
        .{
            .usage = c.VMA_MEMORY_USAGE_AUTO,
            .flags = c.VMA_ALLOCATION_CREATE_MAPPED_BIT | c.VMA_ALLOCATION_CREATE_HOST_ACCESS_SEQUENTIAL_WRITE_BIT,
        },
    );
    index_buffer.copy(u32, indices);

    // var allocated_surfaces: std.ArrayList(GeoSurface) = try .initCapacity(allocator, geo_surfaces.len);
    // allocated_surfaces.appendSliceAssumeCapacity(geo_surfaces);

    return .{
        .index_buffer = index_buffer,
        .vertex_buffer = vertex_buffer,
        // .surfaces = allocated_surfaces,
        .name = try gpa.dupe(u8, name),
    };
}

pub fn deinit(self: *@This(), gpa: std.mem.Allocator, vma: Vma) void {
    self.index_buffer.deinit(vma);
    self.vertex_buffer.deinit(vma);
    gpa.free(self.name);
    // self.surfaces.deinit(allocator);
}
