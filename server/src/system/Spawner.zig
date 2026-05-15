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

const max_despawn_count: u32 = 1000;

gpa: std.mem.Allocator,
world: *system.World,
physics: *Physics,
network_pending_spawn: std.ArrayList(SpawnEntity) = .empty,
network_pending_despawn: std.ArrayList(u32) = .empty,

pending_despawn: std.ArrayList(u32) = .empty,

pub fn init(self: *@This(), gpa: std.mem.Allocator, world: *system.World, physics: *Physics) !void {
    self.* = .{
        .gpa = gpa,
        .world = world,
        .physics = physics,
        .pending_despawn = try .initCapacity(gpa, max_despawn_count),
    };
}
pub fn deinit(self: *@This()) void {
    self.network_pending_despawn.deinit(self.gpa);
    self.network_pending_spawn.deinit(self.gpa);
    self.pending_despawn.deinit(self.gpa);
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
    // std.log.debug("despawn ID: {d}", .{entity_id});
    self.pending_despawn.appendAssumeCapacity(entity_id);
}

pub fn update(self: *@This(), info: *const system.Info) !void {
    _ = info;
    // for (info.world.entities.values()) |*entity| {
    //     if (entity.kind == .enemy) {
    //         try self.depspawn(entity.id);
    //     }
    // }
    std.debug.assert(self.pending_despawn.items.len < max_despawn_count);
    for (self.pending_despawn.items) |entity_id| {
        if (self.world.getPtr(entity_id)) |entity| {
            if (entity.flags.collider) {
                if (entity.collider.body_id) |body_id| self.physics.destroyBody(body_id);
                std.log.debug("DESTROY body_id={any} for entity id={d} kind={s}", .{
                    entity.collider.body_id, entity.id, @tagName(entity.kind),
                });
            }
            if (!self.world.despawn(entity_id)) @panic("fack");
            try self.network_pending_despawn.append(self.gpa, entity_id);
        }
    }
    self.pending_despawn.clearRetainingCapacity();
}
