const std = @import("std");
const system = @import("../system.zig");
const shared = @import("shared");
const Info = system.Info;
const nz = shared.nz;

const SpawnEntity = struct {
    kind: shared.EntityKind,
    id: u32,
};

const max_despawn_count: u32 = 1000;

gpa: std.mem.Allocator,
world: *system.World,

pending_despawn: std.ArrayList(u32) = .empty,

pub fn init(self: *@This(), gpa: std.mem.Allocator, world: *system.World) !void {
    self.* = .{
        .gpa = gpa,
        .world = world,
        .pending_despawn = try .initCapacity(gpa, max_despawn_count),
    };
}
pub fn deinit(self: *@This()) void {
    self.pending_despawn.deinit(self.gpa);
}

pub fn spawn(self: *@This(), entity_info: system.Entity) !*system.Entity {
    const entity = try self.world.spawn();
    const id: u32 = entity.id;
    entity.* = entity_info;
    entity.id = id;
    return entity;
}

pub fn depspawn(self: *@This(), entity_id: u32) !void {
    // std.log.debug("despawn ID: {d}", .{entity_id});
    self.pending_despawn.appendAssumeCapacity(entity_id);
}

pub fn update(self: *@This(), info: *const system.Info) !void {
    _ = info;
    std.debug.assert(self.pending_despawn.items.len < max_despawn_count);
    for (self.pending_despawn.items) |entity_id| {
        if (self.world.get(entity_id)) |entity| {
            _ = entity;
            _ = self.world.despawn(entity_id);
        }
    }
    self.pending_despawn.clearRetainingCapacity();
}
