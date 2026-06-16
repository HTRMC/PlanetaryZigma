const std = @import("std");
const system = @import("../system.zig");
const shared = @import("shared");
const Info = system.Info;
const nz = shared.numz;
const Model = @import("../Renderer/Vulkan/GltfModel.zig");
const Renderer = @import("../Renderer/Vulkan.zig");
const Node = @import("../Renderer/Vulkan/Node.zig");

gpa: std.mem.Allocator,

pub fn init(self: *@This(), gpa: std.mem.Allocator) void {
    self.* = .{ .gpa = gpa };
}

pub fn update(
    self: *@This(),
    info: *const Info,
    models: *std.EnumMap(shared.Entity.Kind, *Model),
) !void {
    _ = self;

    // std.log.debug("render ptr {*}, model ptr{*}", .{ self.renderer, models });
    for (info.world.entities.values()) |*entity| {
        const model = models.get(entity.kind) orelse return;
        if (model.animations.items.len == 0) continue;
        const animation = &model.animations.items[model.active_animation];
        entity.animation_info.time += info.delta_time;

        if (entity.animation_info.time > animation.end) entity.animation_info.time -= animation.end;
        for (animation.channels.items) |*channel| {
            const sampler = animation.samplers.items[channel.sampler_index];
            for (0..sampler.inputs.items.len - 1) |i| {
                const sampler_in = sampler.inputs.items[i];
                const sampler_in_next = sampler.inputs.items[i + 1];
                if (entity.animation_info.time >= sampler_in and entity.animation_info.time <= sampler_in_next) {
                    const interpolate_value: f32 = (entity.animation_info.time - sampler_in) / (sampler_in_next - sampler_in);
                    const node = channel.node orelse return error.NoNode;
                    const sampler_out = sampler.outputs.items[i];
                    const sampler_out_next = sampler.outputs.items[i + 1];
                    switch (channel.path) {
                        .translation => {
                            const new_val = std.math.lerp(
                                sampler_out,
                                sampler_out_next,
                                @as(nz.Vec4(f32), @splat(interpolate_value)),
                            );
                            node.translation = .{ new_val[0], new_val[1], new_val[2] };
                        },
                        .rotation => {
                            node.rotation = nz.Quat(f32).slerp(
                                .{ .w = sampler_out[3], .x = sampler_out[0], .y = sampler_out[1], .z = sampler_out[2] },
                                .{ .w = sampler_out_next[3], .x = sampler_out_next[0], .y = sampler_out_next[1], .z = sampler_out_next[2] },
                                interpolate_value,
                            );
                        },
                        .scale => {
                            const new_val = std.math.lerp(
                                sampler_out,
                                sampler_out_next,
                                @as(nz.Vec4(f32), @splat(interpolate_value)),
                            );
                            node.scale = .{ new_val[0], new_val[1], new_val[2] };
                        },
                        .weights => {
                            return error.WeightsNotImplemented;
                        },
                    }
                }
            }
        }
        for (model.top_nodes.items) |node| {
            var top_matrix: nz.Mat4x4(f32) = .identity;
            node.refreshMatrices(model.nodes, &top_matrix);
        }
        for (model.top_nodes.items) |node| {
            updateJoints(node, model);
        }
    }
}

fn updateJoints(node: *Node, model: *Model) void {
    if (node.skin_id > -1) {
        const skin = &model.skins.items[@intCast(node.skin_id)];
        const inverse_bind_matrices = skin.inverse_bind_matrices.?;
        const inverse_transform: nz.Mat4x4(f32) = node.world_matrix.inverse();
        const joint_matrices: [*]nz.Mat4x4(f32) = @ptrCast(@alignCast(skin.buffer.?.info.pMappedData));
        for (skin.joints.items, 0..) |joint, i| {
            joint_matrices[i] = inverse_transform.mul(joint.world_matrix.mul(inverse_bind_matrices.items[i]));
        }
    }
    for (node.children.items) |child_id| {
        // std.log.debug("Update Child", .{node.translation});
        updateJoints(&model.nodes.items[child_id], model);
    }
}
