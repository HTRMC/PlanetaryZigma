const std = @import("std");
const c = @import("vulkan");
const nz = @import("shared").nz;
const Buffer = @import("Buffer.zig");
const Vma = @import("Vma.zig");
const Device = @import("device.zig").Logical;

pub const max_ui_quads: usize = 1024;

pub const Vertex = extern struct {
    position: [2]f32,
    uv: [2]f32,
    color: [4]f32,
};

pub const Quad = struct {
    vertices: [4]Vertex,
};

index_buffer: Buffer,
ui_quads: std.ArrayList(Quad) = .empty,

pub fn init(gpa: std.mem.Allocator, vma: Vma, device: Device) !@This() {
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
        .index_buffer = ui_index_buffer,
        .ui_quads = try .initCapacity(gpa, max_ui_quads),
    };
}

pub fn deinit(self: *@This(), gpa: std.mem.Allocator, vma: Vma) void {
    self.index_buffer.deinit(vma);
    self.ui_quads.deinit(gpa);
}
