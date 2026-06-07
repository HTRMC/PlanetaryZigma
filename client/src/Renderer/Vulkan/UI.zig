const std = @import("std");
const nz = @import("shared").nz;
const Buffer = @import("Buffer.zig");

pub const Vertex = packed struct {
    position: [2]f32,
    uv: [2]f32,
    color: [4]f32,
};

index_buffer: Buffer,
ui_quads: std.ArrayList(Vertex) = .empty,
