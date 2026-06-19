const std = @import("std");
const c = @import("vulkan");
const nz = @import("shared").numz;
const ext = @import("procs.zig").device.ProcTable;
const Buffer = @import("Buffer.zig");
const Device = @import("device.zig").Logical;
const Vma = @import("Vma.zig");
const Node = @import("Node.zig");

name: []const u8,
buffer: ?Buffer,
skeleton_root: ?*Node,
inverse_bind_matrices: ?std.ArrayList(nz.Mat4x4(f32)),
joints: []usize,

pub fn init(
    gpa: std.mem.Allocator,
    vma: Vma,
    device: Device,
    name: []const u8,
    inversse_bind_matrices: ?[]nz.Mat4x4(f32),
    root: ?*Node,
    joints: []usize,
) !@This() {
    return .{
        .name = try gpa.dupe(u8, name),
        .buffer = if (inversse_bind_matrices) |matrices| try .init(
            device,
            vma,
            nz.Mat4x4(f32),
            matrices.len,
            c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT | c.VK_BUFFER_USAGE_2_RESOURCE_DESCRIPTOR_BUFFER_BIT_EXT | c.VK_BUFFER_USAGE_2_SHADER_DEVICE_ADDRESS_BIT,
            .{
                .usage = Vma.c.VMA_MEMORY_USAGE_CPU_TO_GPU,
                .flags = Vma.c.VMA_ALLOCATION_CREATE_MAPPED_BIT,
            },
        ) else null,
        .inverse_bind_matrices = if (inversse_bind_matrices) |matrices| .fromOwnedSlice(matrices) else null,
        .skeleton_root = root,
        .joints = joints,
    };
}

pub fn deinit(self: *@This(), gpa: std.mem.Allocator, vma: Vma) void {
    if (self.buffer) |*buffer| buffer.deinit(vma);
    gpa.free(self.name);
    if (self.inverse_bind_matrices) |*matrices| matrices.deinit(gpa);
    gpa.free(self.joints);
}
