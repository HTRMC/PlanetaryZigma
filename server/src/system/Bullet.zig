const std = @import("std");
const shared = @import("shared");
const system = @import("../system.zig");
const Physics = @import("Physics.zig");
const Spawner = @import("Spawner.zig");
const nz = shared.numz;

const gravity_acceleration: f32 = 100;

gpa: std.mem.Allocator,
physics: *Physics,
spawner: *Spawner,
to_despawn: std.ArrayList(u32) = .empty,

pub fn init(self: *@This(), gpa: std.mem.Allocator, physics: *Physics, spawner: *Spawner) !void {
    self.* = .{
        .gpa = gpa,
        .physics = physics,
        .spawner = spawner,
    };
}

pub fn deinit(self: *@This()) void {
    self.to_despawn.deinit(self.gpa);
}

pub fn update(self: *@This(), info: *const system.Info) !void {
    const query = self.physics.physics_system.getNarrowPhaseQuery();
    const dt = info.delta_time;

    self.to_despawn.clearRetainingCapacity();

    for (info.world.entities.values()) |*entity| {
        if (!entity.flags.bullet or !entity.flags.transform) continue;
        const bullet = &entity.bullet;

        bullet.lifetime -= dt;
        if (bullet.lifetime <= 0) {
            try self.to_despawn.append(self.gpa, entity.id);
            continue;
        }

        const up = nz.vec.normalize(entity.transform.position);
        bullet.velocity += nz.vec.scale(-up, gravity_acceleration * dt);

        const p0 = entity.transform.position;
        const segment = nz.vec.scale(bullet.velocity, dt);

        const result = query.castRay(.{
            .origin = .{ p0[0], p0[1], p0[2], 1 },
            .direction = .{ segment[0], segment[1], segment[2], 0 },
        }, .{});

        if (result.has_hit) {
            const bodies = self.physics.physics_system.getBodiesUnsafe();
            if (Physics.zphy.tryGetBody(bodies, result.hit.body_id)) |hit_body| {
                const target_id: u32 = @intCast(hit_body.user_data);
                if (target_id == bullet.owner_id) {
                    entity.transform.position = p0 + segment;
                    continue;
                }
                try self.to_despawn.append(self.gpa, entity.id);
            }
        } else {
            entity.transform.position = p0 + segment;
        }
    }

    for (self.to_despawn.items) |id| {
        try self.spawner.depspawn(id);
    }
}
