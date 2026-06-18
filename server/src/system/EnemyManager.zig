const std = @import("std");
const shared = @import("shared");
const tracy = @import("ztracy");
const nz = shared.numz;
const system = @import("../system.zig");
const Spawner = @import("Spawner.zig");
const Physics = @import("Physics.zig");
const HealthManager = @import("HealthManager.zig");
const Info = system.Info;

gpa: std.mem.Allocator,
world: *system.World,

pub fn init(self: *@This(), gpa: std.mem.Allocator, world: *system.World, spawner: *Spawner) !void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();
    self.* = .{
        .gpa = gpa,
        .world = world,
    };
    const planet_size: u32 = 100;
    const planet: shared.Planet(.logical) = try .init(self.gpa, planet_size);
    _ = try spawner.spawn(.{
        .kind = .planet,
        .planet = planet_size,
        .transform = .{},
        .collider = .{
            .shape = .{
                .mesh = .{
                    .indices = planet.indices,
                    .vertices = planet.vertices,
                },
            },
            .motion_type = .static,
        },
        .flags = .{ .transform = true, .collider = true, .planet = true },
    });
}

pub fn deinit(self: *@This()) !void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();
    _ = self;
}

pub fn update(self: *@This(), info: *const Info, physics: *const Physics, health_manager: *HealthManager) !void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();
    _ = self;

    // std.log.debug("\n\neneties: {d}\n\n", .{info.world.entities.entries.len});
    var player: *system.Entity = undefined;
    for (info.world.entities.values()) |*entity| {
        if (entity.kind == .player) {
            player = entity;
            break;
        }
    } else return;

    const body_interface = physics.physics_system.getBodyInterfaceMut();

    var planet_size: f32 = 0;
    for (info.world.entities.values()) |*entity| {
        if (entity.flags.planet == true) {
            planet_size = @floatFromInt(entity.planet);
            break;
        }
    }
    for (info.world.entities.values()) |*entity| {
        if (entity.kind != .enemy) continue;
        if (!entity.flags.transform or !entity.flags.collider) continue;
        const body_id = entity.collider.body_id orelse continue;

        const to_player = player.transform.position - entity.transform.position;
        const distance = nz.vec.length(to_player);

        // entity.transform = player.transform;

        // Skip entities at (or near) world origin — planet_up is undefined there
        // and `nz.vec.normalize` returns the input unchanged on zero length.
        const up_len = nz.vec.length(entity.transform.position);
        if (up_len < 0.0001) continue;
        const planet_up = nz.vec.scale(entity.transform.position, 1.0 / up_len);

        // Project onto the tangent plane so enemies yaw toward the player but never pitch.
        // Skips when projection is degenerate (player on top of, or along up from, the enemy).
        const fwd_proj = to_player - nz.vec.scale(planet_up, nz.vec.dot(to_player, planet_up));
        if (nz.vec.length(fwd_proj) > 0.0001) {
            const forward = nz.vec.normalize(fwd_proj);
            const rot = nz.quat.Hamiltonian(f32).lookAt(forward, planet_up).normalize();
            body_interface.setRotation(body_id, rot.toVec(), .activate);
        }

        if (distance < 4) {
            if (entity.attack_cooldown >= 1) {
                entity.attack_cooldown = 0;
                if (!health_manager.removeHealth(player, entity.damage)) std.log.debug("did not take damage", .{});
            } else {
                entity.attack_cooldown += info.delta_time;
            }
        } else {
            entity.attack_cooldown = 0;
        }

        if (distance < 10) continue;
        const power: u32 = 1000000;
        const force = nz.vec.scale(nz.vec.normalize(entity.transform.forward()), power);
        // body_interface.addImpulse(body_id, force);
        body_interface.addForce(body_id, force);
        // body_interface.setPosition(body_id, player.transform.position, .activate);
    }
}
