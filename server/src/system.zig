const std = @import("std");
const shared = @import("shared");
const NetworkManager = @import("system/NetworkManager.zig");
const Spawner = @import("system/Spawner.zig");
const Game = @import("system/Game.zig");
const tracy = @import("ztracy");
const nz = shared.numz;
const Physics = @import("system/Physics.zig");
const PlayerController = @import("system/PlayerController.zig");
const CameraController = @import("system/CameraController.zig");
const Bullet = @import("system/Bullet.zig");

pub const Info = struct {
    delta_time: f32,
    elapsed_time: f32,
    world: *World,
};

pub const Camera = struct {
    pub const Mode = enum { follow, free };

    mode: Mode = .follow,
    yaw_rotation: nz.quat.Hamiltonian(f32) = .identity,
    pitch: f32 = 0,
    boom_offset: nz.Vec3(f32) = .{ 0, 0, 0 },
    transform: nz.Transform3D(f32) = .{},
};

pub const Controller = struct {
    attack_cool_down: f32 = 0,

    input: shared.net.Command.Input = .{},
};

pub const BulletData = struct {
    velocity: nz.Vec3(f32) = .{ 0, 0, 0 },
    damage: f32 = 1,
    lifetime: f32 = 5,
    owner_id: u32 = 0,
};

pub const Health = struct {
    current: f32 = 0,
    max: f32 = 0,
};

pub const Entity = struct {
    id: u32 = 0,
    flags: Flags = .{},
    kind: shared.Entity.Kind = .unknown,

    transform: nz.Transform3D(f32) = .{},
    collider: Physics.Collider = undefined,
    controller: Controller = .{},
    camera: Camera = .{},
    planet: u32 = 0,
    bullet: BulletData = .{},
    health: Health = .{},

    pub const Flags = packed struct {
        transform: bool = false,
        collider: bool = false,
        controller: bool = false,
        camera: bool = false,
        planet: bool = false,
        align_to_planet: bool = false, //TODO: if not aligned jolt needs DOF awareness for later
        bullet: bool = false,
        health: bool = false,
    };

    pub fn deinit(self: *Entity, gpa: std.mem.Allocator) void {
        const tracy_scope = tracy.zone(@src());
        defer tracy_scope.end();
        if (self.flags.collider) {
            switch (self.collider.shape) {
                .mesh => |*mesh| {
                    gpa.free(mesh.indices);
                    gpa.free(mesh.vertices);
                },
                .primitive => {},
            }
        }
    }
};

pub const World = struct {
    pub const max_entities: usize = 1024;
    gpa: std.mem.Allocator,
    entities: std.AutoArrayHashMapUnmanaged(u32, Entity) = .empty,
    next_id: u32 = 1,

    pub fn init(gpa: std.mem.Allocator) !@This() {
        const tracy_scope = tracy.zone(@src());
        defer tracy_scope.end();
        var entities: std.AutoArrayHashMapUnmanaged(u32, Entity) = .empty;
        try entities.ensureTotalCapacity(gpa, max_entities);

        return .{
            .gpa = gpa,
            .entities = entities,
        };
    }
    pub fn deinit(self: *@This()) void {
        const tracy_scope = tracy.zone(@src());
        defer tracy_scope.end();
        for (self.entities.values()) |*entity| {
            entity.deinit(self.gpa);
        }
        self.entities.deinit(self.gpa);
    }

    pub fn spawn(self: *@This()) !*Entity {
        const tracy_scope = tracy.zone(@src());
        defer tracy_scope.end();
        std.debug.assert(self.entities.entries.len < max_entities);
        const id = self.next_id;
        self.next_id += 1;
        self.entities.putAssumeCapacity(id, .{ .id = id });
        return self.entities.getPtr(id).?;
    }

    pub fn getPtr(self: *@This(), id: u32) ?*Entity {
        const tracy_scope = tracy.zone(@src());
        defer tracy_scope.end();
        return self.entities.getPtr(id);
    }

    pub fn despawn(self: *@This(), id: u32) bool {
        const tracy_scope = tracy.zone(@src());
        defer tracy_scope.end();
        if (self.entities.getPtr(id)) |entity| entity.deinit(self.gpa);
        return self.entities.swapRemove(id);
    }
};

pub const Context = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    world: *World,
    steam_server: *shared.SteamNet.Server,
    network_manager: NetworkManager,
    physics: Physics,
    player_controller: PlayerController,
    camera_controller: CameraController,
    spawner: Spawner,
    game: Game,
    bullet: Bullet,
    request_exit: bool = false,

    pub const Data = struct {
        gpa: std.mem.Allocator,
        world: *World,
        io: std.Io,
        steam_server: *shared.SteamNet.Server,
    };

    pub fn init(self: *@This(), data: *const Data) !void {
        const tracy_scope = tracy.zone(@src());
        defer tracy_scope.end();
        self.* = .{
            .gpa = data.gpa,
            .io = data.io,
            .world = data.world,
            .steam_server = data.steam_server,
            .spawner = undefined,
            .game = undefined,
            .network_manager = undefined,
            .physics = undefined,
            .player_controller = undefined,
            .camera_controller = undefined,
            .bullet = undefined,
        };
        try self.physics.init(data.gpa, data.io);
        try self.player_controller.init(&self.physics, &self.spawner);
        try self.camera_controller.init();
        try self.spawner.init(data.gpa, data.world, &self.physics);
        try self.bullet.init(data.gpa, self.world, &self.physics, &self.spawner);
        try self.game.init(data.gpa, data.world, &self.spawner);
        try self.network_manager.init(data.gpa, data.io, data.steam_server);
    }
    pub fn deinit(self: *@This()) !void {
        const tracy_scope = tracy.zone(@src());
        defer tracy_scope.end();
        self.physics.deinit();
        try self.network_manager.deinit();
        try self.game.deinit();
        self.bullet.deinit();
        self.spawner.deinit();
    }

    pub fn update(self: *@This(), info: *const Info) !void {
        const tracy_scope = tracy.zone(@src());
        defer tracy_scope.end();
        try self.network_manager.update(info, &self.spawner);
        try self.player_controller.update(info);
        try self.game.update(info, &self.physics);
        try self.physics.update(info);
        try self.bullet.update(info);
        try self.camera_controller.update(info);
        try self.spawner.update(info);
        // self.request_exit = true;
        // if (info.elapsed_time > 1) self.request_exit = true;
    }
    fn reload(self: *@This(), pre_reload: bool) !void {
        const tracy_scope = tracy.zone(@src());
        defer tracy_scope.end();
        std.log.debug("before-1", .{});
        try self.physics.reload(pre_reload, self.world);
        try self.network_manager.reload(pre_reload);
        std.log.debug("before-0", .{});
    }
};

comptime {
    _ = ffi;
}

pub const ffi = struct {
    pub const Table = struct {
        systemContextInit: *const fn (*Context, data: *const Context.Data) callconv(.c) void,
        systemContextDeinit: *const fn (*Context) callconv(.c) void,
        systemContextUpdate: *const fn (*Context, data: *const Info) callconv(.c) void,
        systemContextReload: *const fn (*Context, pre_reload: bool) callconv(.c) void,

        pub fn load(dynlib: *shared.DynLib) !@This() {
            const tracy_scope = tracy.zone(@src());
            defer tracy_scope.end();
            var self: @This() = undefined;
            inline for (@typeInfo(@This()).@"struct".fields) |field| {
                std.log.debug("Looking up symbol: {s}", .{field.name});
                const ptr = dynlib.lookup(field.type, field.name);
                if (ptr) |p| {
                    @field(self, field.name) = p;
                } else {
                    std.log.err("Failed to lookup symbol: {s}", .{field.name});
                    return error.DynlibLookup;
                }
            }
            return self;
        }
    };

    pub export fn systemContextInit(context: *Context, data: *const Context.Data) void {
        const tracy_scope = tracy.zone(@src());
        defer tracy_scope.end();
        std.log.debug("system context init", .{});
        context.init(data) catch |err| {
            if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
            std.log.err("context init: {s}", .{@errorName(err)});
            return;
        };
    }

    pub export fn systemContextDeinit(context: *Context) void {
        const tracy_scope = tracy.zone(@src());
        defer tracy_scope.end();
        std.log.debug("system context deinit", .{});
        context.deinit() catch |err| {
            if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
            std.log.err("context init: {s}", .{@errorName(err)});
            return;
        };
        context.* = undefined;
    }

    pub export fn systemContextUpdate(context: *Context, info: *const Info) void {
        const tracy_scope = tracy.zone(@src());
        defer tracy_scope.end();
        const result = context.update(info);
        result catch |err| {
            if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
            std.log.err("context update: {any}", .{@errorName(err)});
            return;
        };
    }
    pub export fn systemContextReload(context: *Context, pre_reload: bool) void {
        const tracy_scope = tracy.zone(@src());
        defer tracy_scope.end();
        const result = context.reload(pre_reload);
        result catch |err| {
            if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
            std.log.err("context update: {any}", .{@errorName(err)});
            return;
        };
    }
};
