const std = @import("std");
const builtin = @import("builtin");
const system = @import("system");
const shared = @import("shared");
const World = system.World;
const nz = shared.numz;
const steam = @import("steamworks");

/// Virtual port both sides agree on. Lets the server distinguish "I'm the
/// PlanetaryZigma server" from any other thing on the same SteamID.
pub const virtual_port: i32 = 42;

pub fn main(init: std.process.Init) !void {
    var gpa_impl = if (builtin.mode == .Debug) std.heap.DebugAllocator(.{ .verbose_log = false }).init else init.gpa;
    defer {
        if (builtin.mode == .Debug) _ = gpa_impl.deinit();
    }
    const gpa = gpa_impl.allocator();
    const io = init.io;

    if (!steam.SteamAPI_Init()) @panic("failed to init steamworks");
    defer steam.SteamAPI_Shutdown();

    steam.SteamAPI_ManualDispatch_Init();
    const pipe = steam.SteamAPI_GetHSteamPipe();

    std.log.info("STEAM_ID {d}", .{steam.SteamUser().GetSteamID()});

    const sock = steam.SteamNetworkingSockets_SteamAPI();
    const listen = sock.CreateListenSocketP2P(virtual_port, &.{});
    if (listen == 0) return error.ListenFailed;
    std.log.info("listening on virtual port {d}", .{virtual_port});

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

        _ = try steamCallback(pipe, sock);

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

pub fn steamCallback(pipe: steam.HSteamPipe, sock: ?steam.ISteamNetworkingSockets) !i32 {
    steam.SteamAPI_ManualDispatch_RunFrame(pipe);
    var msg: steam.CallbackMsg_t = undefined;
    while (steam.SteamAPI_ManualDispatch_GetNextCallback(pipe, &msg)) {
        defer steam.SteamAPI_ManualDispatch_FreeLastCallback(pipe);
        switch (msg.m_iCallback) {
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
                    .k_ESteamNetworkingConnectionState_ClosedByPeer,
                    .k_ESteamNetworkingConnectionState_ProblemDetectedLocally,
                    => {
                        if (sock) |s| _ = s.CloseConnection(ev.m_hConn, 0, "peer-closed", false);
                    },
                    else => {},
                }
                return msg.m_iCallback;
            },
            else => {
                return msg.m_iCallback;
            },
        }
    }
    return -1;
}
