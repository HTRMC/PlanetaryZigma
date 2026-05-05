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
stream: std.Io.net.Stream,
server_address: std.Io.net.IpAddress,
server_listen: std.Io.Future(@typeInfo(@TypeOf(listen)).@"fn".return_type.?),
command_queue: shared.net.CommandQueue = .{},
spawner: *Spawner,

pub fn init(
    self: *@This(),
    gpa: std.mem.Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
    server_address: std.Io.net.IpAddress,
    spawner: *Spawner,
) !void {
    self.* = .{
        .gpa = gpa,
        .io = io,
        .stream = stream,
        .server_address = server_address,
        .server_listen = try io.concurrent(listen, .{ gpa, io, stream, &self.command_queue }),
        .spawner = spawner,
    };
}

pub fn deinit(self: *@This()) !void {
    self.server_listen.cancel(self.io) catch |err| {
        switch (err) {
            error.Canceled => std.log.err("err: {s}", .{@errorName(err)}),
            error.Unexpected => std.log.err("err: {s}", .{@errorName(err)}),
            else => {
                std.log.err("err: {s}", .{@errorName(err)});
                return err;
            },
        }
    };
    try self.command_queue.deinit(self.gpa, self.io);
}

pub fn listen(gpa: std.mem.Allocator, io: std.Io, stream: std.Io.net.Stream, command_queue: *shared.net.CommandQueue) !void {
    std.log.debug("hello 1", .{});
    var buffer: [1024]u8 = undefined;
    while (true) {
        const msg = stream.socket.receive(io, &buffer) catch |err| {
            if (err == error.WouldBlock) continue;
            return err;
        };
        _ = msg;

        var msg_reader: std.Io.Reader = .fixed(&buffer);
        const reader = &msg_reader;

        const parsed = try shared.net.Command.parse(reader);

        // if (parsed.command == .spawn_entity) {
        // std.log.debug("Spanned: {any}", .{parsed.command});
        // }

        try command_queue.mutex.lock(io);
        try command_queue.commands.append(gpa, parsed.command);
        command_queue.mutex.unlock(io);
    }
}

pub fn update(self: *@This(), system_context: *system.Context, info: *const Info) !void {
    var fixed_writer_buffer: [1024]u8 = undefined;
    var fix_writer: std.Io.Writer = .fixed(&fixed_writer_buffer);
    const writer = &fix_writer;
    for (info.world.entities.values()) |*entity| {
        if (!entity.flags.camera or !entity.flags.transform) continue;

        try self.sendCommand(writer, .{ .input = entity.camera.input_map });
        entity.camera.input_map.mouse_wheel = 0;
        break;
    }
    try self.command_queue.mutex.lock(self.io);
    for (self.command_queue.commands.items) |command| switch (command) {
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
            std.log.debug("ACK: MY ID: {d}, server ID: {d} ", .{ new_player.id, command.acknowledge.id });
        },
        .spawn_entity => |spawn_entity| {
            const server_id = command.spawn_entity.id;
            if (info.world.enitity_mapping.contains(server_id)) continue;
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
                    std.log.debug("SPAWNED: Planet ", .{});
                    new_entity.mesh = .{ .id = @intCast(vulkan_mesh_handle) };
                },
                .enemy => new_entity.mesh = .{ .id = 0 },
                .bullet => {
                    new_entity.mesh = .{ .id = 0 };
                    new_entity.transform.scale = @splat(0.1);
                },
                .unknown => @panic("unknown entity type... wtf"),
            }

            try info.world.enitity_mapping.put(self.gpa, command.spawn_entity.id, new_entity.id);
            std.log.debug("spawn entities : {d}", .{info.world.next_id});
            std.log.debug("SPAWNED: MY ID: {d}, server ID: {d} ", .{ new_entity.id, command.spawn_entity.id });
        },
        .despawn_entity => {
            const server_id = command.despawn_entity.id;
            const my_id = info.world.enitity_mapping.get(server_id) orelse {
                std.log.debug("FAILED TO GET- SERVER ID: {d},  ", .{server_id});
                continue;
            };
            try self.spawner.depspawn(my_id);
            std.log.debug("DESPAWNED: MY ID: {d}, server ID: {d} ", .{ my_id, server_id });
        },
        .update_transform => {
            const update_transform_command = command.update_transform;
            const id = info.world.enitity_mapping.get(update_transform_command.id) orelse continue;
            const entity = info.world.get(id) orelse continue;
            entity.transform.position = update_transform_command.position;
            entity.transform.rotation = .fromVec(update_transform_command.rotation);
        },
        .update_camera_rotation => {
            const rotation_command = command.update_camera_rotation;
            const id = info.world.enitity_mapping.get(rotation_command.id) orelse continue;
            const entity = info.world.get(id) orelse continue;
            entity.camera.transform.rotation = .fromVec(rotation_command.rotation);
            entity.camera.transform.position = rotation_command.position;
        },
        else => {
            std.log.err("Unhandled command {s}", .{@tagName(command)});
        },
    };
    // self.command_queue.commands.clearAndFree(self.allocator);
    self.command_queue.commands.items.len = 0;
    self.command_queue.mutex.unlock(self.io);
}
pub fn sendCommand(self: @This(), writer: *std.Io.Writer, command: shared.net.Command) !void {
    writer.end = 0;
    try command.write(writer);
    try self.stream.socket.send(self.io, &self.server_address, writer.buffer);
}
