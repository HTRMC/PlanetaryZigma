const std = @import("std");
const builtin = @import("builtin");
const system = @import("system");
const shared = @import("shared");
const World = system.World;
const nz = shared.numz;
const steam = @import("steamworks");

const max_connections: usize = 32;

var connections: [max_connections]steam.HSteamNetConnection = @splat(0);

fn addConnection(conn: steam.HSteamNetConnection) void {
    for (&connections) |*slot| {
        if (slot.* == 0) {
            slot.* = conn;
            return;
        }
    }
    std.log.err("connection table full; dropping conn={d}", .{conn});
}

fn removeConnection(conn: steam.HSteamNetConnection) void {
    for (&connections) |*slot| {
        if (slot.* == conn) {
            slot.* = 0;
            return;
        }
    }
}

pub fn main(init: std.process.Init) !void {
    var gpa_impl = if (builtin.mode == .Debug) std.heap.DebugAllocator(.{ .verbose_log = false }).init else init.gpa;
    defer {
        if (builtin.mode == .Debug) _ = gpa_impl.deinit();
    }
    const gpa = gpa_impl.allocator();
    const io = init.io;

    if (!steam.Server.SteamInternal_GameServer_Init(
        0,
        27016,
        27015,
        steam.STEAMGAMESERVER_QUERY_PORT_SHARED,
        steam.EServerMode.eServerModeAuthentication,
        "1.0.0.0",
    )) @panic("failed to init steam game server");
    defer steam.Server.SteamGameServer_Shutdown();

    const gs = steam.SteamGameServer();
    gs.SetGameDescription("Planetary Zigma dedicated server");
    gs.SetModDir("planetaryzigma");
    gs.SetDedicatedServer(true);
    gs.SetMaxPlayerCount(16);
    gs.SetServerName("Planetary Zigma");
    gs.SetMapName("default");
    gs.SetPasswordProtected(false);
    gs.LogOnAnonymous();
    gs.SetAdvertiseServerActive(true);

    steam.SteamAPI_ManualDispatch_Init();
    const pipe = steam.SteamGameServer_GetHSteamPipe();

    var connected = false;
    var deadline: u32 = 0;
    while (!connected and deadline < 1000) : (deadline += 1) {
        switch (try steamCallback(gpa, pipe, null, null)) {
            101 => connected = true,
            else => {},
        }
        try io.sleep(.{ .nanoseconds = std.time.ns_per_s }, .real);
    }
    if (!connected) return error.LogonTimeout;

    std.log.info("STEAM_ID {d}", .{gs.GetSteamID()});

    const sock = steam.SteamGameServerNetworkingSockets_SteamAPI();
    const listen = sock.CreateListenSocketP2P(0, &.{});
    if (listen == 0) return error.ListenFailed;

    var net: shared.SteamNet = .{};
    defer net.deinit(gpa);

    var watcher: shared.Watcher = try .init("system_server_", io);
    defer watcher.deinit(io);
    try watcher.load(io);

    var world: World = try .init(gpa);
    defer world.deinit();

    var system_context: system.Context = undefined;
    var system_table: system.ffi.Table = try .load(&watcher.dynlib.?);

    system_table.systemContextInit(&system_context, &system.Context.Data{
        .io = io,
        .world = &world,
        .gpa = gpa,
        .net = &net,
    });
    defer system_table.systemContextDeinit(&system_context);

    var count: usize = 0;
    var accumlated_time: f32 = 0;
    var elapsed_time: f32 = 0;
    var delta_time: f32 = 0;
    const time_step: f32 = 0.0167;
    while (true) {
        if (system_context.request_exit) break;

        _ = try steamCallback(gpa, pipe, sock, &net);
        try drainIncoming(gpa, sock, &net);

        delta_time = getDeltaTime(io);
        accumlated_time += delta_time;
        if (accumlated_time < time_step) continue;
        elapsed_time += time_step;
        accumlated_time -= time_step;
        try world.mutex.lock(io);
        count += 1;

        system_table.systemContextUpdate(&system_context, &.{ .delta_time = time_step, .elapsed_time = elapsed_time, .world = &world });
        flushOutgoing(sock, &net);

        if (try watcher.reload(io)) {
            system_table.systemContextReload(&system_context, true);
            std.log.debug("system table updated", .{});
            watcher.old_dynlib.?.close();
            watcher.old_dynlib = null;
            system_table = try .load(&watcher.dynlib.?);
            system_table.systemContextReload(&system_context, false);
        }
        world.mutex.unlock(io);
    }
}

pub fn getDeltaTime(io: std.Io) f32 {
    const static = struct {
        var previous: ?std.Io.Timestamp = null;
    };

    const now: std.Io.Timestamp = .now(io, .real);
    const prev = static.previous orelse {
        static.previous = now;
        return getDeltaTime(io);
    };

    const dt_ns = prev.durationTo(now);
    static.previous = now;

    return @as(f32, @floatFromInt(dt_ns.nanoseconds)) / 1_000_000_000.0;
}

fn drainIncoming(gpa: std.mem.Allocator, sock: steam.ISteamNetworkingSockets, net: *shared.SteamNet) !void {
    var msgs: [16][*c]steam.SteamNetworkingMessage_t = undefined;
    for (connections) |conn| {
        if (conn == 0) continue;
        const n = sock.ReceiveMessagesOnConnection(conn, &msgs[0], @intCast(msgs.len));
        if (n <= 0) continue;
        const cnt: usize = @intCast(n);
        for (msgs[0..cnt]) |raw| {
            if (raw == null) continue;
            const m: *steam.SteamNetworkingMessage_t = raw;
            defer m.Release();
            if (m.m_pData == null or m.m_cbSize <= 0) continue;
            const bytes = m.m_pData[0..@intCast(m.m_cbSize)];
            try net.pushIncoming(gpa, conn, bytes);
        }
    }
}

fn flushOutgoing(sock: steam.ISteamNetworkingSockets, net: *shared.SteamNet) void {
    if (net.outgoing.items.len == 0) return;
    for (net.outgoing.items) |*msg| {
        var msg_num: i64 = 0;
        _ = sock.SendMessageToConnection(msg.conn, msg.bytes[0..msg.len], steam.k_nSteamNetworkingSend_Reliable, &msg_num);
    }
    net.outgoing.clearRetainingCapacity();
}

pub fn steamCallback(
    gpa: std.mem.Allocator,
    pipe: steam.HSteamPipe,
    sock: ?steam.ISteamNetworkingSockets,
    net: ?*shared.SteamNet,
) !i32 {
    steam.SteamAPI_ManualDispatch_RunFrame(pipe);
    var msg: steam.CallbackMsg_t = undefined;
    while (steam.SteamAPI_ManualDispatch_GetNextCallback(pipe, &msg)) {
        defer steam.SteamAPI_ManualDispatch_FreeLastCallback(pipe);
        switch (msg.m_iCallback) {
            102 => return error.SteamServersConnectFailure,
            1221 => {
                const data = msg.data() orelse return msg.m_iCallback;
                const ev = data.SteamNetConnectionStatusChangedCallback;
                std.log.info("server net state: {s} (conn={d})", .{ @tagName(ev.m_info.m_eState), ev.m_hConn });
                switch (ev.m_info.m_eState) {
                    .k_ESteamNetworkingConnectionState_Connecting => {
                        if (sock) |s| {
                            const r = s.AcceptConnection(ev.m_hConn);
                            std.log.info("AcceptConnection -> {s}", .{@tagName(r)});
                        }
                    },
                    .k_ESteamNetworkingConnectionState_Connected => {
                        addConnection(ev.m_hConn);
                        if (net) |n| try n.pushEvent(gpa, .{ .connected = ev.m_hConn });
                    },
                    .k_ESteamNetworkingConnectionState_ClosedByPeer,
                    .k_ESteamNetworkingConnectionState_ProblemDetectedLocally,
                    => {
                        if (sock) |s| _ = s.CloseConnection(ev.m_hConn, 0, "peer-closed", false);
                        removeConnection(ev.m_hConn);
                        if (net) |n| try n.pushEvent(gpa, .{ .disconnected = ev.m_hConn });
                    },
                    else => {},
                }
                return msg.m_iCallback;
            },
            else => return msg.m_iCallback,
        }
    }
    return -1;
}
