const std = @import("std");
const nz = @import("shared").numz;
const Node = @import("Node.zig");

const Sampler = struct {
    interpolation: []const u8,
    inputs: std.ArrayList(f32) = .empty,
    outputs: std.ArrayList(nz.vec4) = .empty,
};

const Channel = struct {
    path: []const u8,
    node: *Node,
    sapler_index: u32,
};

name: []const u8,
samplers: std.ArrayList(Sampler),
channels: std.ArrayList(Channel),
start: f32 = std.math.floatMax(f32),
min: f32 = std.math.floatMin(f32),
current_time: f32 = 0,
