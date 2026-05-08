const std = @import("std");
const builtin = @import("builtin");
const system = @import("system");
const shared = @import("shared");
const World = system.World;
const nz = shared.numz;
const steam = @import("steamworks");

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
        switch (try steamCallback(pipe)) {
            101 => connected = true,
            else => {},
        }
        try io.sleep(.{ .nanoseconds = std.time.ns_per_s }, .real);
    }
    if (!connected) return error.LogonTimeout;

    std.log.debug("connected", .{});

    const sock = steam.SteamGameServerNetworkingSockets_SteamAPI();
    const listen = sock.CreateListenSocketP2P(0, &.{});
    if (listen == 0) return error.ListenFailed;

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
    });
    defer system_table.systemContextDeinit(&system_context);

    var count: usize = 0;
    var accumlated_time: f32 = 0;
    var elapsed_time: f32 = 0;
    var delta_time: f32 = 0;
    const time_step: f32 = 0.0167;
    while (true) {
        if (system_context.request_exit) break;

        _ = try steamCallback(pipe);

        delta_time = getDeltaTime(io);
        accumlated_time += delta_time;
        if (accumlated_time < time_step) continue;
        elapsed_time += time_step;
        accumlated_time -= time_step;
        try world.mutex.lock(io);
        count += 1;

        system_table.systemContextUpdate(&system_context, &.{ .delta_time = time_step, .elapsed_time = elapsed_time, .world = &world });
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

pub fn steamCallback(pipe: steam.HSteamPipe) !i32 {
    steam.SteamAPI_ManualDispatch_RunFrame(pipe);
    var msg: steam.CallbackMsg_t = undefined;
    while (steam.SteamAPI_ManualDispatch_GetNextCallback(pipe, &msg)) {
        defer steam.SteamAPI_ManualDispatch_FreeLastCallback(pipe);
        switch (msg.m_iCallback) {
            102 => return error.SteamServersConnectFailure,
            else => {
                return msg.m_iCallback;
            },
        }
    }
    std.log.debug("callback", .{});
    return -1;
}
