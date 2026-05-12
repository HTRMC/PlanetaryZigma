const std = @import("std");
const shared = @import("shared");
const system = @import("../system.zig");
const World = system.World;
const Planet = @import("../Renderer/Vulkan/Mesh.zig").Planet;
const Spawner = @import("Spawner.zig");
const Info = system.Info;
const nz = shared.numz;

gpa: std.mem.Allocator,
io: std.Io,
steam_client: *shared.SteamNet.Client,
spawner: *Spawner,
/// Active connection to the server (0 = not yet connected). Filled in from
/// SteamNet.events on the first .connected event.
server_conn: shared.SteamNet.Conn = 0,
/// Whether we've sent the "connect" handshake on the current server_conn.
sent_connect: bool = false,

pub fn init(
    self: *@This(),
    gpa: std.mem.Allocator,
    io: std.Io,
    net: *shared.SteamNet.Client,
    spawner: *Spawner,
) !void {
    self.* = .{
        .gpa = gpa,
        .io = io,
        .steam_client = net,
        .spawner = spawner,
    };
}

pub fn deinit(self: *@This()) !void {
    if (self.server_conn != 0) self.sendDisconnect() catch {};
}

fn sendDisconnect(self: *@This()) !void {
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const cmd: shared.net.Command = .disconnect;
    try cmd.write(&w);
    try self.steam_client.packets.pushOutgoing(self.gpa, self.server_conn, w.buffered(), .reliable);
}

fn sendConnect(self: *@This()) !void {
    const name = "lucas";
    const cmd: shared.net.Command = .{ .connect = .{ .name_len = name.len, .name = name } };
    try self.sendCommand(cmd, .reliable);
}

pub fn sendCommand(self: *@This(), command: shared.net.Command, flags: shared.SteamNet.SendFlags) !void {
    if (self.server_conn == 0) return;
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try command.write(&w);
    try self.steam_client.packets.pushOutgoing(self.gpa, self.server_conn, w.buffered(), flags);
}

pub fn update(self: *@This(), system_context: *system.Context, info: *const Info) !void {
    try self.steam_client.packet_mutex.lock(self.io);

    // 1. Drain lifecycle events.
    for (self.steam_client.packets.events.items) |ev| switch (ev) {
        .connected => |conn| {
            self.server_conn = conn;
            self.sent_connect = false;
        },
        .disconnected => |conn| {
            if (self.server_conn == conn) {
                self.server_conn = 0;
                self.sent_connect = false;
            }
        },
    };
    self.steam_client.packets.events.clearRetainingCapacity();

    // 2. Handshake once per fresh connection.
    if (self.server_conn != 0 and !self.sent_connect) {
        try self.sendConnect();
        self.sent_connect = true;
    }

    // 3. Send our input.
    if (self.server_conn != 0) {
        for (info.world.entities.values()) |*entity| {
            if (!entity.flags.camera or !entity.flags.transform) continue;
            try self.sendCommand(.{ .input = entity.camera.input_map }, .reliable);
            entity.camera.input_map.mouse_wheel = 0;
            break;
        }
    }

    std.log.debug("cmd size {d}", .{self.steam_client.packets.incoming.items.len});
    // 4. Drain inbound commands.
    for (self.steam_client.packets.incoming.items) |*msg| {
        if (msg.conn != self.server_conn) continue;
        var msg_reader: std.Io.Reader = .fixed(&msg.bytes);
        const reader = &msg_reader;
        const parsed = shared.net.Command.parse(reader) catch |err| {
            std.log.err("parse command: {s}", .{@errorName(err)});
            continue;
        };
        try self.handleCommand(system_context, info, parsed.command);
    }
    self.steam_client.packets.incoming.clearRetainingCapacity();
    self.steam_client.packet_mutex.unlock(self.io);
}

fn handleCommand(self: *@This(), system_context: *system.Context, info: *const Info, command: shared.net.Command) !void {
    switch (command) {
        .acknowledge => |acknowledge| {
            const new_player = try self.spawner.spawn(.{
                .camera = .{ .transform = .{ .position = .{ 0, 0, 0 } } },
                .transform = .{ .position = .{ 0, 0, 0 } },
                .mesh = .{ .id = 0 },
                .flags = .{ .camera = true, .transform = true, .mesh = true },
            });
            try info.world.enitity_mapping.put(self.gpa, acknowledge.id, new_player.id);
            info.world.my_server_id = acknowledge.id;
            std.log.debug("ack entities: {d}", .{info.world.next_id});
            std.log.debug("ACK: MY ID: {d}, server ID: {d} ", .{ new_player.id, acknowledge.id });
        },
        .spawn_entity => |spawn_entity| {
            const server_id = spawn_entity.id;
            if (info.world.enitity_mapping.contains(server_id)) return;
            const new_entity = try self.spawner.spawn(.{
                .transform = .{ .position = .{ 0, 0, 0 } },
                .flags = .{ .transform = true, .mesh = true },
            });
            switch (spawn_entity.kind) {
                .player => new_entity.mesh = .{ .id = 0 },
                .planet => {
                    const size: u32 = @intCast(spawn_entity.data[0]);
                    var planet_vertices: Planet = try .init(self.gpa, size);
                    defer planet_vertices.deinit(self.gpa);
                    system_context.planet.vertices = try .initCapacity(self.gpa, planet_vertices.vertices.items.len);
                    system_context.planet.indices = try .initCapacity(self.gpa, planet_vertices.indices.items.len);
                    system_context.planet.indices.appendSliceAssumeCapacity(planet_vertices.indices.items);
                    system_context.planet.vertices.appendSliceAssumeCapacity(planet_vertices.vertices.items);
                    const vulkan_mesh_handle = try system_context.renderer.inner.createMesh(
                        self.gpa,
                        "planet",
                        planet_vertices.indices.items,
                        system_context.planet.vertices.items,
                    );
                    std.log.debug("SPAWNED: Planet {d}", .{size});
                    new_entity.mesh = .{ .id = @intCast(vulkan_mesh_handle) };
                },
                .enemy => new_entity.mesh = .{ .id = 0 },
                .bullet => {
                    new_entity.mesh = .{ .id = 0 };
                    new_entity.transform.scale = @splat(0.1);
                },
                .unknown => @panic("unknown entity type... wtf"),
            }
            try info.world.enitity_mapping.put(self.gpa, spawn_entity.id, new_entity.id);
            // std.log.debug("spawn entities : {d}", .{info.world.next_id});
            // std.log.debug("SPAWNED: MY ID: {d}, server ID: {d} ", .{ new_entity.id, spawn_entity.id });
        },
        .despawn_entity => |despawn_entity| {
            const server_id = despawn_entity.id;
            const my_id = info.world.enitity_mapping.get(server_id) orelse {
                std.log.debug("FAILED TO GET- SERVER ID: {d},  ", .{server_id});
                return;
            };
            try self.spawner.depspawn(my_id);
            // std.log.debug("DESPAWNED: MY ID: {d}, server ID: {d} ", .{ my_id, server_id });
        },
        .update_transform => |update_transform_command| {
            const id = info.world.enitity_mapping.get(update_transform_command.id) orelse return;
            const entity = info.world.get(id) orelse return;
            entity.transform.position = update_transform_command.position;
            entity.transform.rotation = .fromVec(update_transform_command.rotation);
        },
        .update_camera_rotation => |rotation_command| {
            const id = info.world.enitity_mapping.get(rotation_command.id) orelse return;
            const entity = info.world.get(id) orelse return;
            entity.camera.transform.rotation = .fromVec(rotation_command.rotation);
            entity.camera.transform.position = rotation_command.position;
        },
        else => std.log.err("Unhandled command {s}", .{@tagName(command)}),
    }
}
