const std = @import("std");
const system = @import("../system.zig");
const shared = @import("shared");
const Physics = @import("Physics.zig");
const Info = system.Info;
const nz = shared.nz;

const SpawnEntity = struct {
    kind: shared.EntityKind,
    id: u32,
};

gpa: std.mem.Allocator,
world: *system.World,
physics: *Physics,
network_pending_spawn: std.ArrayList(SpawnEntity) = .empty,
network_pending_despawn: std.ArrayList(u32) = .empty,

pub fn init(self: *@This(), gpa: std.mem.Allocator, world: *system.World, physics: *Physics) !void {
    self.* = .{
        .gpa = gpa,
        .world = world,
        .physics = physics,
    };
}
pub fn deinit(self: *@This()) void {
    self.network_pending_despawn.deinit(self.gpa);
    self.network_pending_spawn.deinit(self.gpa);
}

// pub fn spawnConnectPlayer(self: *@This()) !u32 {
//     const entity = try self.world.spawn();
//     entity.kind = .player;
//     entity.transform = .{ .position = .{ 0, 0, 100 } };
//     entity.collider = .{
//         .shape = .{ .primitive = .{ .box = .{ .size = 1 } } },
//         .motion_type = .dynamic,
//     };
//     entity.camera = .{ .transform = .{ .position = .{ 0, 0, 100 } } };
//     entity.flags = .{
//         .transform = true,
//         .collider = true,
//         .input = true,
//         .camera = true,
//     };
//     try self.physics.createBody(entity);
//
//     try self.network_pending_spawn.append(self.gpa, .{ .id = entity.id, .kind = .player });
//     return entity.id;
// }

pub fn spawnEnemy(self: *@This()) !u32 {
    const entity = try self.world.spawn();
    entity.kind = .enemy;
    entity.transform = .{ .position = .{ 0, 0, 100 } };
    entity.collider = .{
        .shape = .{ .primitive = .{ .box = .{ .size = 1 } } },
        .motion_type = .dynamic,
    };
    entity.flags = .{ .transform = true, .collider = true, .align_to_planet = true };
    try self.physics.createBody(entity);

    try self.network_pending_spawn.append(self.gpa, .{ .id = entity.id, .kind = .enemy });
    return entity.id;
}

pub fn spawnPlanet(self: *@This()) !u32 {
    const planet_entity = try self.world.spawn();
    const planet_size: u32 = 100;
    planet_entity.kind = .planet;
    planet_entity.planet = planet_size;
    planet_entity.transform = .{};
    const planet: shared.Planet = try .init(self.gpa, planet_size);
    std.log.debug("size: {d}", .{@sizeOf(system.Entity)});
    std.log.debug("vert: {d}, triangles {d}", .{ planet.indices.items.len, planet.indices.items.len / 3 });

    planet_entity.collider = .{
        .shape = .{
            .mesh = .{
                .indices = planet.indices,
                .vertices = planet.vertices,
            },
        },
        .motion_type = .static,
    };
    planet_entity.flags = .{ .transform = true, .collider = true, .planet = true };
    try self.physics.createBody(planet_entity);
    std.log.debug("OK ", .{});
    return planet_entity.id;
}

pub fn spawn(self: *@This(), entity_info: system.Entity) !*system.Entity {
    // std.log.debug("SIZE: {d}", .{self.world.entities.entries.len});
    const entity = try self.world.spawn();
    const id: u32 = entity.id;
    entity.* = entity_info;
    entity.id = id;
    if (entity.flags.collider) {
        try self.physics.createBody(entity);
    }
    try self.network_pending_spawn.append(self.gpa, .{ .id = entity.id, .kind = entity.kind });
    return entity;
}

pub fn depspawn(self: *@This(), entity_id: u32) !void {
    std.log.debug("despawn ID: {d}", .{entity_id});
    if (self.world.get(entity_id)) |entity| {
        if (entity.flags.collider) {
            if (entity.collider.body_id) |body_id| self.physics.destroyBody(body_id);
        }
    }
    _ = self.world.despawn(entity_id);
    try self.network_pending_despawn.append(self.gpa, entity_id);
}

pub fn update(self: *@This()) !void {
    _ = self;
}
