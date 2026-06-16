const std = @import("std");
const shared = @import("shared");
const tracy = @import("ztracy");
const nz = shared.numz;
const yes = @import("yes");
const NetworkManager = @import("system/NetworkManager.zig");
const AssetServer = @import("shared").AssetServer;
const Spawner = @import("system/Spawner.zig");
const Animation = @import("system/Animations.zig");
pub const Renderer = @import("Renderer.zig");

pub const Camera = @import("system/Camera.zig");

pub const Info = struct {
    delta_time: f32,
    elapsed_time: f32,
    world: *World,
};

pub const Entity = struct {
    pub const Flags = packed struct {
        transform: bool = false,
        model: bool = false,
        screen_space: bool = false,
    };
    pub const Model = struct {
        id: u32 = 0,
    };

    id: u32 = 0,
    flags: Flags = .{},

    model: Model = .{},
    transform: nz.Transform3D(f32) = .{},

    pub fn deinit(self: *Entity, gpa: std.mem.Allocator) void {
        const tracy_scope = tracy.zone(@src());
        defer tracy_scope.end();
        _ = self;
        _ = gpa;
    }
};

pub const World = struct {
    mutex: std.Io.Mutex = .init,
    gpa: std.mem.Allocator,
    entities: std.AutoArrayHashMapUnmanaged(u32, Entity) = .empty,
    next_id: u32 = 1,
    enitity_mapping: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    my_server_id: u32 = 0,
    camera: Camera = .{},

    pub fn init(gpa: std.mem.Allocator) !@This() {
        const tracy_scope = tracy.zone(@src());
        defer tracy_scope.end();
        return .{ .gpa = gpa };
    }
    pub fn deinit(self: *@This()) void {
        const tracy_scope = tracy.zone(@src());
        defer tracy_scope.end();
        for (self.entities.values()) |*entity| entity.deinit(self.gpa);
        self.entities.deinit(self.gpa);
        self.enitity_mapping.deinit(self.gpa);
    }

    pub fn spawn(self: *@This()) !*Entity {
        const tracy_scope = tracy.zone(@src());
        defer tracy_scope.end();
        const id = self.next_id;
        self.next_id += 1;
        try self.entities.put(self.gpa, id, .{ .id = id });
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
    platform: yes.Platform,
    window: *yes.Window,
    steam_client: *shared.SteamNet.Client,
    asset_server: *AssetServer,
    renderer: Renderer,
    network_manager: NetworkManager,
    spawner: Spawner,
    animation: Animation,
    planet: ?shared.Planet(.renderable),

    pub const Data = struct {
        gpa: std.mem.Allocator,
        io: std.Io,
        platform: yes.Platform,
        window: *yes.Window,
        asset_server: *AssetServer,
        world: *World,
        steam_client: *shared.SteamNet.Client,
    };

    pub fn init(self: *@This(), data: Data) !void {
        const tracy_scope = tracy.zone(@src());
        defer tracy_scope.end();
        self.gpa = data.gpa;
        self.io = data.io;
        self.platform = data.platform;
        self.window = data.window;
        self.steam_client = data.steam_client;
        self.asset_server = data.asset_server;
        self.renderer = try .init(data.gpa, data.asset_server, data.platform, data.window);
        try self.spawner.init(data.gpa, data.world);
        try self.network_manager.init(data.gpa, data.io, data.steam_client, &self.spawner);
        self.animation.init(data.gpa);
        self.planet = null;
    }

    pub fn deinit(self: *@This()) void {
        const tracy_scope = tracy.zone(@src());
        defer tracy_scope.end();
        self.renderer.deinit(self.gpa);
        self.network_manager.deinit();
        if (self.planet) |*p| p.deinit(self.gpa);
        self.spawner.deinit();
    }

    pub fn update(self: *@This(), info: *const Info) !void {
        const tracy_scope = tracy.zone(@src());
        defer tracy_scope.end();
        try info.world.camera.update(info, &self.network_manager, &self.renderer.inner.ui);
        try self.renderer.update(info);
        try self.animation.update(info, &self.renderer.inner.models);
        try self.asset_server.update();
        try self.network_manager.update(self, info);
        try self.spawner.update(info);
    }

    pub fn eventUpdate(self: *@This(), info: *const Info, event: *const yes.Window.Event) !void {
        const tracy_scope = tracy.zone(@src());
        defer tracy_scope.end();
        _ = self;
        try info.world.camera.eventUpdate(info, event);
    }
    fn reload(self: *@This(), pre_reload: bool) !void {
        const tracy_scope = tracy.zone(@src());
        defer tracy_scope.end();
        if (pre_reload) {
            std.log.debug("pre-hotreload", .{});
            self.renderer.deinit(self.gpa);
        } else {
            std.log.debug("post-hotreload", .{});
            self.renderer = try .init(self.gpa, self.asset_server, self.platform, self.window);
            if (self.planet) |p| {
                const vulkan_mesh_handle = try self.renderer.inner.createModelWithMesh(
                    self.gpa,
                    "planet",
                    p.vertices,
                    p.indices,
                );
                //TODO: take care of handle matching
                _ = vulkan_mesh_handle;
            }
        }
    }
};

comptime {
    _ = ffi;
}

pub const ffi = struct {
    pub const Table = struct {
        systemContextInit: *const fn (*Context, data: *const Context.Data) callconv(.c) void,
        systemContextDeinit: *const fn (*Context) callconv(.c) void,
        systemContextUpdate: *const fn (*Context, data: *const Info, event: ?*const yes.Window.Event) callconv(.c) void,
        systemContextReload: *const fn (*Context, pre_reload: bool) callconv(.c) void,

        pub fn load(dynlib: *shared.DynLib) !@This() {
            const tracy_scope = tracy.zone(@src());
            defer tracy_scope.end();
            var self: @This() = undefined;
            inline for (@typeInfo(@This()).@"struct".fields) |field| {
                std.log.debug("Looking up symbol: {s}", .{field.name});
                const ptr = dynlib.lookup(field.type, field.name) orelse {
                    std.log.err("Failed to lookup symbol: {s}", .{field.name});
                    return error.DynlibLookup;
                };
                @field(self, field.name) = ptr;
            }
            return self;
        }
    };

    pub export fn systemContextInit(context: *Context, data: *const Context.Data) void {
        const tracy_scope = tracy.zone(@src());
        defer tracy_scope.end();
        std.log.debug("system context init", .{});
        context.init(data.*) catch |err| {
            if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
            std.log.err("context init: {s}", .{@errorName(err)});
            return;
        };
    }

    pub export fn systemContextDeinit(context: *Context) void {
        const tracy_scope = tracy.zone(@src());
        defer tracy_scope.end();
        std.log.debug("system context deinit", .{});
        context.deinit();
        context.* = undefined;
    }

    pub export fn systemContextUpdate(context: *Context, info: *const Info, event: ?*const yes.Window.Event) void {
        const tracy_scope = tracy.zone(@src());
        defer tracy_scope.end();
        const result = if (event != null) context.eventUpdate(info, event.?) else context.update(info);
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
