const std = @import("std");
const shared = @import("shared");
const system = @import("../system.zig");
const Spawner = @import("Spawner.zig");
const Info = system.Info;

gpa: std.mem.Allocator,
io: std.Io,
accept_client_future: std.Io.Future(@typeInfo(@TypeOf(Client.accept)).@"fn".return_type.?),
socket: std.Io.net.Socket,
clients: std.AutoHashMap(std.Io.net.IpAddress, Client),

pub const Client = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    server_socket: std.Io.net.Socket,
    name: []const u8,
    entity_id: u32 = 0,
    needs_full_sync: bool = true,
    command_queue: shared.net.CommandQueue = .{},
    ip_address: std.Io.net.IpAddress,

    pub fn accept(gpa: std.mem.Allocator, io: std.Io, socket: std.Io.net.Socket, clients: *std.AutoHashMap(std.Io.net.IpAddress, @This())) !void {
        var buffer: [1024]u8 = undefined;
        while (true) {
            const msg = try socket.receive(io, &buffer);
            _ = msg.from; // Sender's address
            _ = msg.data; // Received data (slice of buffer)
            _ = msg.flags;

            var msg_reader: std.Io.Reader = .fixed(&buffer);
            const reader = &msg_reader;

            const parsed = try shared.net.Command.parse(reader);
            // std.log.debug("Spanned: {any}", .{parsed.command});

            if (parsed.command == .connect) {
                const connect = parsed.command.connect;
                try clients.put(msg.from, undefined);
                const client = clients.getPtr(msg.from).?;
                client.* = .{
                    .gpa = gpa,
                    .io = io,
                    .server_socket = socket,
                    .name = try gpa.dupe(u8, connect.name),
                    .ip_address = msg.from,
                };
            }

            var client = clients.getPtr(msg.from).?;
            try client.command_queue.mutex.lock(io);
            try client.command_queue.commands.append(gpa, parsed.command);
            client.command_queue.mutex.unlock(io);
        }
    }

    pub fn sendCommand(self: *@This(), writer: *std.Io.Writer, command: shared.net.Command) !void {
        writer.end = 0;
        try command.write(writer);
        try self.server_socket.send(self.io, &self.ip_address, writer.buffer);
    }

    pub fn deinit(self: *@This()) !void {
        self.gpa.free(self.name);
        self.command_queue.deinit(self.gpa, self.io);
    }
};

pub fn init(self: *@This(), gpa: std.mem.Allocator, io: std.Io) !void {
    self.* = .{
        .gpa = gpa,
        .io = io,
        .socket = try shared.net.address.bind(io, .{ .protocol = .udp, .mode = .dgram }),
        .clients = .init(gpa),
        .accept_client_future = try io.concurrent(Client.accept, .{ gpa, io, self.socket, &self.clients }),
    };
}

pub fn deinit(self: *@This()) !void {
    self.accept_client_future.cancel(self.io) catch |err| {
        switch (err) {
            error.Canceled => std.log.err("err: {s}", .{@errorName(err)}),
            error.Unexpected => std.log.err("err: {s}", .{@errorName(err)}),
            else => {
                std.log.err("err: {s}", .{@errorName(err)});
                return err;
            },
        }
    };
}

pub fn reload(self: *@This(), pre_reload: bool) !void {
    if (pre_reload) try self.accept_client_future.cancel(self.io) else {
        std.log.debug("RELOAD", .{});
        self.accept_client_future = try self.io.concurrent(Client.accept, .{ self.gpa, self.io, self.socket, &self.clients });

        //NOTE: do full resync for all clients on hotreload?
        var it = self.clients.iterator();
        while (it.next()) |pair| {
            pair.value_ptr.needs_full_sync = true;
        }
    }
}

pub fn update(self: *@This(), info: *const Info, spawner: *Spawner) !void {
    const world = info.world;

    var fixed_writer_buffer: [1024]u8 = undefined;
    var fix_writer: std.Io.Writer = .fixed(&fixed_writer_buffer);
    const writer = &fix_writer;

    var it = self.clients.iterator();
    while (it.next()) |pair| {
        const client = pair.value_ptr;
        // const client_address = pair.key_ptr;
        try client.command_queue.mutex.lock(self.io);

        for (client.command_queue.commands.items) |command| {
            switch (command) {
                .connect => {
                    const new_player_entity = try spawner.spawn(.{
                        .kind = .player,
                        .transform = .{ .position = .{ 0, 0, 100 } },
                        .collider = .{
                            .shape = .{ .primitive = .{ .box = .{ .size = 1 } } },
                            .motion_type = .dynamic,
                        },
                        .camera = .{ .transform = .{ .position = .{ 0, 0, 100 } } },
                        .flags = .{
                            .transform = true,
                            .collider = true,
                            .controller = true,
                            .camera = true,
                        },
                    });
                    client.entity_id = new_player_entity.id;
                    try client.sendCommand(writer, .{ .acknowledge = .{ .id = client.entity_id } });
                    std.log.debug("New Player ID: {d}\n", .{client.entity_id});
                },
                .disconnect => {
                    try spawner.depspawn(client.entity_id);
                    std.log.debug("player disconnect", .{});
                },
                .input => {
                    // std.log.debug("got input from {d}", .{client.entity_id});
                    if (world.get(client.entity_id)) |entity| {
                        entity.controller.input = command.input;
                    }
                },
                else => {
                    std.log.err("Unhandled command {s}", .{@tagName(command)});
                },
            }
        }
        client.command_queue.commands.clearRetainingCapacity();
        client.command_queue.mutex.unlock(self.io);
    }

    it = self.clients.iterator();
    while (it.next()) |pair| {
        const client = pair.value_ptr;

        //update camera
        if (world.get(client.entity_id)) |player_entity| {
            const camera = player_entity.camera;
            try client.sendCommand(writer, .{ .update_camera_rotation = .{ .position = camera.transform.position, .rotation = camera.transform.rotation.toVec(), .id = client.entity_id } });
        }

        //spawns
        if (client.needs_full_sync) {
            std.log.debug("FULL SYNC", .{});
            for (world.entities.values()) |*entity| {
                if (!entity.flags.transform) continue;
                std.log.debug("sent id {d}", .{entity.id});
                var data: [4]u8 = @splat(0);
                switch (entity.kind) {
                    .planet => data = @bitCast(entity.planet),
                    else => {},
                }
                try client.sendCommand(writer, .{ .spawn_entity = .{
                    .id = entity.id,
                    .kind = entity.kind,
                    .data = data,
                } });
            }
            client.needs_full_sync = false;
        } else {
            for (spawner.network_pending_spawn.items) |entry| {
                try client.sendCommand(writer, .{ .spawn_entity = .{ .id = entry.id, .kind = entry.kind } });
            }
        }
        //despawns
        for (spawner.network_pending_despawn.items) |id| {
            try client.sendCommand(writer, .{ .despawn_entity = .{ .id = id } });
        }
        //Update Transforms
        for (world.entities.values()) |*entity| {
            if (!entity.flags.transform) continue;
            try client.sendCommand(writer, .{ .update_transform = .{
                .id = entity.id,
                .position = entity.transform.position,
                .rotation = entity.transform.rotation.toVec(),
            } });
        }
    }
    spawner.network_pending_despawn.clearRetainingCapacity();
    spawner.network_pending_spawn.clearRetainingCapacity();

    // for (clients_to_remove.items) |client| {
    //     _ = self.clients.remove(client.ip.*);
    // }
    // for (clients_to_remove.items) |client| {
    //     writer.end = 0;
    //     try client.client.command_queue.mutex.lock(self.io);
    //     const remove_entity_cmd: shared.net.Command = .{ .despawn_entity = .{ .id = client.client.entity_id } };
    //     try remove_entity_cmd.write(writer);
    //     try self.socket.send(self.io, client.ip, writer.buffered());
    //     client.client.command_queue.mutex.unlock(self.io);
    // }
}
