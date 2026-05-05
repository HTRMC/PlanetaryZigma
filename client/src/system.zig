const std = @import("std");
const shared = @import("shared");
const nz = shared.numz;
const yes = @import("yes");
const NetworkManager = @import("system/NetworkManager.zig");
const AssetServer = @import("shared").AssetServer;
const Spawner = @import("system/Spawner.zig");
pub const Renderer = @import("Renderer.zig");

pub const Camera = @import("system/Camera.zig");
pub const Mesh = struct {
    id: u32,
};

pub const Info = struct {
    delta_time: f32,
    elapsed_time: f32,
    world: *World,
};

pub const Entity = struct {
    pub const Flags = packed struct(u32) {
        transform: bool = false,
        camera: bool = false,
        mesh: bool = false,
        _pad: u29 = 0,
    };

    id: u32 = 0,
    flags: Flags = .{},

    transform: nz.Transform3D(f32) = .{},
    camera: Camera = .{},
    mesh: Mesh = .{ .id = 0 },

    pub fn deinit(self: *Entity, gpa: std.mem.Allocator) void {
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

    pub fn init(gpa: std.mem.Allocator) !@This() {
        return .{ .gpa = gpa };
    }
    pub fn deinit(self: *@This()) void {
        for (self.entities.values()) |*entity| entity.deinit(self.gpa);
        self.entities.deinit(self.gpa);
        self.enitity_mapping.deinit(self.gpa);
    }

    pub fn spawn(self: *@This()) !*Entity {
        const id = self.next_id;
        self.next_id += 1;
        try self.entities.put(self.gpa, id, .{ .id = id });
        return self.entities.getPtr(id).?;
    }

    pub fn get(self: *@This(), id: u32) ?*Entity {
        return self.entities.getPtr(id);
    }

    pub fn despawn(self: *@This(), id: u32) bool {
        if (self.entities.getPtr(id)) |entity| entity.deinit(self.gpa);
        return self.entities.swapRemove(id);
    }
};

pub const Context = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    platform: yes.Platform,
    window: *yes.Window,
    server_address: std.Io.net.IpAddress,
    server_stream: std.Io.net.Stream,
    asset_server: *AssetServer,
    renderer: Renderer,
    network_manager: NetworkManager,
    spawner: Spawner,
    planet: PlanetVertices = undefined,

    pub const PlanetVertices = struct {
        vertices: std.ArrayList(Renderer.Vertex) = .empty,
        indices: std.ArrayList(u32) = .empty,

        pub fn deinit(self: *@This(), gpa: std.mem.Allocator) !void {
            self.indices.deinit(gpa);
            self.vertices.deinit(gpa);
        }
    };

    pub const Data = struct {
        gpa: std.mem.Allocator,
        io: std.Io,
        platform: yes.Platform,
        window: *yes.Window,
        asset_server: *AssetServer,
        world: *World,
    };

    pub fn init(self: *@This(), data: Data) !void {
        self.server_address = try .parse("127.0.0.1", 8080);
        self.server_stream = try self.server_address.connect(data.io, .{ .mode = .dgram, .protocol = .udp });
        self.gpa = data.gpa;
        self.io = data.io;
        self.platform = data.platform;
        self.window = data.window;
        self.asset_server = data.asset_server;
        self.renderer = try .init(data.gpa, data.asset_server, data.platform, data.window);
        try self.spawner.init(data.gpa, data.world);
        try self.network_manager.init(data.gpa, data.io, self.server_stream, self.server_address, &self.spawner);

        const name = "lucas";
        const connect_command: shared.net.Command = .{ .connect = .{
            .name_len = name.len,
            .name = name,
        } };
        var fixed_writer_buffer: [1024]u8 = undefined;
        var fixed_writer: std.Io.Writer = .fixed(&fixed_writer_buffer);
        const writer = &fixed_writer;
        try connect_command.write(writer);
        try self.server_stream.socket.send(self.io, &self.server_address, writer.buffered());
    }

    pub fn deinit(self: *@This()) !void {
        std.log.debug("DEINIT", .{});
        var fixed_writer_buffer: [1024]u8 = undefined;
        var fixed_writer: std.Io.Writer = .fixed(&fixed_writer_buffer);
        const writer = &fixed_writer;
        const disconnect_command: shared.net.Command = .disconnect;
        fixed_writer.end = 0;
        try disconnect_command.write(writer);
        try self.server_stream.socket.send(self.io, &self.server_address, writer.buffered());

        self.renderer.deinit(self.gpa);
        try self.network_manager.deinit();
        self.server_stream.close(self.io);
        try self.planet.deinit(self.gpa);
        self.spawner.deinit();
    }

    pub fn update(self: *@This(), info: *const Info) !void {
        for (info.world.entities.values()) |*entity| {
            if (!entity.flags.camera or !entity.flags.transform) continue;
            entity.camera.update(info);
            try self.renderer.update(info);
            break;
        }
        try self.asset_server.update();
        try self.network_manager.update(self, info);
        try self.spawner.update(info);
    }

    pub fn eventUpdate(self: *@This(), info: *const Info, event: *const yes.Window.Event) !void {
        _ = self;
        for (info.world.entities.values()) |*entity| {
            if (!entity.flags.camera) continue;
            try entity.camera.eventUpdate(info, event);
            break;
        }
    }
    fn reload(self: *@This(), pre_reload: bool) !void {
        std.log.debug("before-0", .{});
        if (pre_reload) {
            self.renderer.deinit(self.gpa);
            try self.network_manager.deinit();
        } else {
            self.renderer = try .init(self.gpa, self.asset_server, self.platform, self.window);
            const vulkan_mesh_handle = try self.renderer.inner.createMesh(
                self.gpa,
                "planet",
                self.planet.indices.items,
                self.planet.vertices.items,
            );
            //TODO: take care of handle matching
            _ = vulkan_mesh_handle;
            try self.network_manager.init(self.gpa, self.io, self.server_stream, self.server_address, &self.spawner);
        }
        std.log.debug("before-1", .{});
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

        pub fn load(dynlib: *std.DynLib) !@This() {
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
        std.log.debug("system context init", .{});
        context.init(data.*) catch |err| {
            if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
            std.log.err("context init: {s}", .{@errorName(err)});
            return;
        };
    }

    pub export fn systemContextDeinit(context: *Context) void {
        std.log.debug("system context deinit", .{});
        context.deinit() catch |err| {
            if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
            std.log.err("context update: {any}", .{@errorName(err)});
            return;
        };
        context.* = undefined;
    }

    pub export fn systemContextUpdate(context: *Context, info: *const Info, event: ?*const yes.Window.Event) void {
        const result = if (event != null) context.eventUpdate(info, event.?) else context.update(info);
        result catch |err| {
            if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
            std.log.err("context update: {any}", .{@errorName(err)});
            return;
        };
    }
    pub export fn systemContextReload(context: *Context, pre_reload: bool) void {
        const result = context.reload(pre_reload);
        result catch |err| {
            if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
            std.log.err("context update: {any}", .{@errorName(err)});
            return;
        };
    }
};
