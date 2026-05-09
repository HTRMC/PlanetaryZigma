const std = @import("std");
const shared = @import("shared");
const system = @import("../system.zig");
const Spawner = @import("Spawner.zig");
const Info = system.Info;

gpa: std.mem.Allocator,
io: std.Io,
net: *shared.SteamNet,
clients: std.AutoHashMap(shared.SteamNet.Conn, Client),

pub const Client = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    net: *shared.SteamNet,
    conn: shared.SteamNet.Conn,
    name: []const u8 = "",
    entity_id: u32 = 0,
    needs_full_sync: bool = true,
    command_queue: shared.net.CommandQueue = .{},

    pub fn sendCommand(self: *@This(), writer: *std.Io.Writer, command: shared.net.Command) !void {
        writer.end = 0;
        try command.write(writer);
        try self.net.pushOutgoing(self.gpa, self.conn, writer.buffered());
    }

    pub fn deinit(self: *@This()) !void {
        if (self.name.len != 0) self.gpa.free(self.name);
        try self.command_queue.deinit(self.gpa, self.io);
    }
};

pub fn init(self: *@This(), gpa: std.mem.Allocator, io: std.Io, net: *shared.SteamNet) !void {
    self.* = .{
        .gpa = gpa,
        .io = io,
        .net = net,
        .clients = .init(gpa),
    };
}

pub fn deinit(self: *@This()) !void {
    var it = self.clients.iterator();
    while (it.next()) |pair| try pair.value_ptr.deinit();
    self.clients.deinit();
}

pub fn reload(self: *@This(), pre_reload: bool) !void {
    _ = self;
    _ = pre_reload;
    // Steam connection state lives in main.zig and survives reload; nothing to
    // tear down or rebuild here.
}

pub fn update(self: *@This(), info: *const Info, spawner: *Spawner) !void {
    const world = info.world;

    // 1. Drain Steam lifecycle events into client map.
    for (self.net.events.items) |ev| switch (ev) {
        .connected => |conn| {
            const gop = try self.clients.getOrPut(conn);
            if (!gop.found_existing) {
                gop.value_ptr.* = .{
                    .gpa = self.gpa,
                    .io = self.io,
                    .net = self.net,
                    .conn = conn,
                };
                std.log.debug("client connected: conn={d}", .{conn});
            }
        },
        .disconnected => |conn| {
            if (self.clients.getPtr(conn)) |client| {
                if (client.entity_id != 0) try spawner.depspawn(client.entity_id);
                try client.deinit();
                _ = self.clients.remove(conn);
                std.log.debug("client disconnected: conn={d}", .{conn});
            }
        },
    };
    self.net.events.clearRetainingCapacity();

    // 2. Drain incoming bytes into the matching client's command queue.
    for (self.net.incoming.items) |*msg| {
        const client = self.clients.getPtr(msg.conn) orelse continue;
        var msg_reader: std.Io.Reader = .fixed(&msg.bytes);
        const reader = &msg_reader;
        const parsed = shared.net.Command.parse(reader) catch |err| {
            std.log.err("parse command: {s}", .{@errorName(err)});
            continue;
        };
        try client.command_queue.commands.append(self.gpa, parsed.command);
    }
    self.net.incoming.clearRetainingCapacity();

    // 3. Process per-client command queues.
    var fixed_writer_buffer: [1024]u8 = undefined;
    var fix_writer: std.Io.Writer = .fixed(&fixed_writer_buffer);
    const writer = &fix_writer;

    var it = self.clients.iterator();
    while (it.next()) |pair| {
        const client = pair.value_ptr;
        for (client.command_queue.commands.items) |command| {
            switch (command) {
                .connect => |connect| {
                    if (client.name.len == 0) client.name = try self.gpa.dupe(u8, connect.name);
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
                    if (client.entity_id != 0) try spawner.depspawn(client.entity_id);
                    std.log.debug("player disconnect", .{});
                },
                .input => {
                    if (world.get(client.entity_id)) |entity| {
                        entity.controller.input = command.input;
                    }
                },
                else => std.log.err("Unhandled command {s}", .{@tagName(command)}),
            }
        }
        client.command_queue.commands.clearRetainingCapacity();
    }

    // 4. Push outbound state to every active client.
    it = self.clients.iterator();
    while (it.next()) |pair| {
        const client = pair.value_ptr;

        // camera
        if (world.get(client.entity_id)) |player_entity| {
            const camera = player_entity.camera;
            try client.sendCommand(writer, .{ .update_camera_rotation = .{
                .position = camera.transform.position,
                .rotation = camera.transform.rotation.toVec(),
                .id = client.entity_id,
            } });
        }

        // spawns
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
        // despawns
        for (spawner.network_pending_despawn.items) |id| {
            try client.sendCommand(writer, .{ .despawn_entity = .{ .id = id } });
        }
        // transforms
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
}
