const std = @import("std");
const c = @import("vulkan");
const nz = @import("shared").numz;
const ext = @import("procs.zig").device.ProcTable;
const Buffer = @import("Buffer.zig");
const Device = @import("device.zig").Logical;
const Vma = @import("Vma.zig");
const Node = @import("Node.zig");

name: []const u8,
buffer: Buffer,
skeleton_root: ?Node,
inverse_bind_matrices: std.ArrayList(nz.Mat4x4(f32)),
// joints: std.ArrayList(*Node),

pub fn init(
    gpa: std.mem.Allocator,
    vma: Vma,
    device: Device,
    name: []const u8,
    inversse_bind_matrices: []nz.Mat4x4(f32),
    // joints: u32,
) !@This() {
    const inverse_matrix_buffer: Buffer = try .init(
        device,
        vma,
        nz.Mat4x4(f32),
        inversse_bind_matrices.len,
        c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT | c.VK_BUFFER_USAGE_2_RESOURCE_DESCRIPTOR_BUFFER_BIT_EXT | c.VK_BUFFER_USAGE_2_SHADER_DEVICE_ADDRESS_BIT,
        .{
            .usage = Vma.c.VMA_MEMORY_USAGE_CPU_TO_GPU,
            .flags = Vma.c.VMA_ALLOCATION_CREATE_MAPPED_BIT,
        },
    );

    return .{
        .name = try gpa.dupe(u8, name),
        .buffer = inverse_matrix_buffer,
        .inverse_bind_matrices = .fromOwnedSlice(inversse_bind_matrices),
        .skeleton_root = null,
    };
}

pub fn deinit(self: *@This(), gpa: std.mem.Allocator, vma: Vma) void {
    self.buffer.deinit(vma);
    gpa.free(self.name);
    self.inverse_bind_matrices.deinit(gpa);
}
