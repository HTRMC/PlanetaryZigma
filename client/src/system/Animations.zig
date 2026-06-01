const std = @import("std");
const system = @import("../system.zig");
const shared = @import("shared");
const Info = system.Info;
const nz = shared.nz;
const Model = @import("../Renderer/Vulkan/GltfModel.zig");
const Node = @import("../Renderer/Vulkan/GltfModel.zig");

gpa: std.mem.Allocator,
models: *std.ArrayList(*Model),

pub fn init(gpa: std.mem.Allocator, models: *std.ArrayList(*Model)) @This() {
    return .{ .gpa = gpa, .models = models };
}

pub fn update(
    self: *@This(),
    info: *const Info,
) !void {
    for (info.world.entities.values()) |*entity| {
        if (!entity.flags.model) continue;
        const model: Model = self.models[entity.model_id];
        const animation = model.animations.items[model.active_animation];
        animation.current_time += info.delta_time;
        if (animation.current_time > animation.end) animation -= animation.end;
        for (animation.channels) |channel| {
            const sampler = animation.samplers.items[channel.sampler_index];
            for (0..sampler.inputs.items.len - 1) |i| {
                const sampler_in = sampler.inputs.items[i];
                const sampler_in_next = sampler.inputs.items[i + 1];
                if (animation.current_time >= sampler_in and animation.current_time <= sampler_in_next) {
                    const interpolate_value: f32 = (animation.current_time - sampler_in) / (sampler_in_next - sampler_in);
                    const node: *Node = channel.node orelse return error.NoNode;
                    const sampler_out = sampler.outputs.items[i];
                    const sampler_out_next = sampler.outputs.items[i + 1];
                    switch (channel.path) {
                        .translation => {
                            node.translation = std.math.lerp(sampler_out, sampler_out_next, interpolate_value);
                        },
                        .rotation => {
                            node.rotation = nz.Quat(f32).slerp(sampler_out, sampler_out_next, interpolate_value);
                        },
                        .scale => {
                            node.scale = std.math.lerp(
                                nz.vec.swizzle.xyz(sampler_out),
                                nz.vec.swizzle.xyz(sampler_out_next),
                                interpolate_value,
                            );
                        },
                        .weights => {
                            return error.WeightsNotImplemented;
                        },
                    }
                }
            }
        }
        for (model.nodes.items) |*node| {
            if (node.skin_id > -1) {
                const inverse_transform: nz.Mat4x4(f32) = node.getLocalMatrix().inverse();
                const skin = model.skins.items[node.skin_id];
                const num_joints = skin.joints.items.len;
                const matrices = skin.inverse_bind_matrices.?;
                for (0..num_joints) |i| {
                    const joint_matrix = model.nodes.items[i].world_matrix;
                    const inverse_matrix = matrices[i];
                    matrices[i] = joint_matrix.mul(inverse_matrix);
                    matrices[i] = inverse_transform * joint_matrix;
                }
            }
        }
    }
}
