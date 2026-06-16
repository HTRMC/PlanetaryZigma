const std = @import("std");
const system = @import("../system.zig");
const shared = @import("shared");
const tracy = @import("ztracy");
const Info = system.Info;
const nz = shared.numz;
const Model = @import("../Renderer/Vulkan/GltfModel.zig");
const Renderer = @import("../Renderer/Vulkan.zig");
const Node = @import("../Renderer/Vulkan/Node.zig");

gpa: std.mem.Allocator,

pub fn init(self: *@This(), gpa: std.mem.Allocator) void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();
    self.* = .{ .gpa = gpa };
}

pub fn update(
    self: *@This(),
    info: *const Info,
    models: *std.ArrayList(*Model),
) !void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();
    _ = self;

    // std.log.debug("render ptr {*}, model ptr{*}", .{ self.renderer, models });
    for (info.world.entities.values()) |*entity| {
        if (!entity.flags.model) continue;
        const model = models.items[entity.model.id];
        if (model.animations.items.len == 0) continue;
        var animation = &model.animations.items[model.active_animation];
        animation.current_time += info.delta_time;

        if (animation.current_time > animation.end) animation.current_time -= animation.end;
        for (animation.channels.items) |*channel| {
            const sampler = animation.samplers.items[channel.sampler_index];
            for (0..sampler.inputs.items.len - 1) |i| {
                const sampler_in = sampler.inputs.items[i];
                const sampler_in_next = sampler.inputs.items[i + 1];
                if (animation.current_time >= sampler_in and animation.current_time <= sampler_in_next) {
                    const interpolate_value: f32 = (animation.current_time - sampler_in) / (sampler_in_next - sampler_in);
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
            node.refreshMatrices(&top_matrix);
        }
        for (model.top_nodes.items) |node| {
            updateJoints(node, model);
        }
    }
}

fn updateJoints(node: *Node, model: *Model) void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();
    if (node.skin_id > -1) {
        const skin = &model.skins.items[@intCast(node.skin_id)];
        const inverse_bind_matrices = skin.inverse_bind_matrices.?;
        const inverse_transform: nz.Mat4x4(f32) = node.world_matrix.inverse();
        const joint_matrices: [*]nz.Mat4x4(f32) = @ptrCast(@alignCast(skin.buffer.?.info.pMappedData));
        for (skin.joints.items, 0..) |joint, i| {
            joint_matrices[i] = inverse_transform.mul(joint.world_matrix.mul(inverse_bind_matrices.items[i]));
        }
    }
    for (node.children.items) |child_node| {
        // std.log.debug("Update Child", .{node.translation});
        updateJoints(child_node, model);
    }
}
