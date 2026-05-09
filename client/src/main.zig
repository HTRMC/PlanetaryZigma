const std = @import("std");
const builtin = @import("builtin");
const shared = @import("shared");
const system = @import("system");
const World = system.World;
const yes = @import("yes");
const Steam = @import("steamworks");

/// Dedicated server's STEAM_ID (printed by server on startup), supplied via
/// the first CLI argument. Zero disables lobby->server advertising and the F2
/// connect path.
var server_steamid: u64 = 0;

/// Virtual port used for self→self ConnectP2P experiment (F4). Must match
/// `virtual_port` in server/src/main.zig when running same-account-self-connect.
const self_connect_virtual_port: i32 = 42;

const State = struct {
    /// Steam lobby we created on startup (so we can write server_steamid into its data).
    own_lobby: u64 = 0,
    /// First lobby returned by the most recent RequestLobbyList; F2 will JoinLobby on it.
    last_match: u64 = 0,
    /// Active P2P connection to the server, if any.
    server_conn: Steam.HSteamNetConnection = 0,
};

var state: State = .{};

pub fn main(init: std.process.Init) !void {
    var gpa_impl = if (builtin.mode == .Debug) std.heap.DebugAllocator(.{ .verbose_log = false }).init else init.gpa;
    defer {
        if (builtin.mode == .Debug) _ = gpa_impl.deinit();
    }
    const gpa = gpa_impl.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len > 1) {
        server_steamid = std.fmt.parseInt(u64, args[1], 10) catch |err| blk: {
            std.log.warn("could not parse server_steamid arg \"{s}\": {s}", .{ args[1], @errorName(err) });
            break :blk 0;
        };
    }
    std.log.info("server_steamid = {d}", .{server_steamid});

    if (!Steam.SteamAPI_Init()) @panic("failed to init steamworks");
    defer Steam.SteamAPI_Shutdown();

    Steam.SteamAPI_ManualDispatch_Init();
    const steam_pipe = Steam.SteamAPI_GetHSteamPipe();

    // Create a public lobby on startup so RequestLobbyList has at least one match.
    // _ = Steam.SteamMatchmaking().CreateLobby(.k_ELobbyTypePublic, 4);

    var cross_platform: yes.Platform.Cross = try .init(gpa, io, init.minimal);
    defer cross_platform.deinit();
    const platform = cross_platform.platform();

    var cross_window: yes.Platform.Cross.Window = .empty(platform);
    const window = cross_window.interface(platform);
    try window.open(platform, .{
        .title = "PlanetaryZigma",
        .size = .{ .width = 600, .height = 400 },
        .resize_policy = .{ .specified = .{
            .min_size = .{ .width = 300, .height = 200 },
        } },
        .surface_type = .vulkan,
    });
    defer window.close(platform);

    var asset_server = try shared.AssetServer.init(gpa, init.io);
    defer asset_server.deinit();

    var world: World = try .init(gpa);
    defer world.deinit();

    var watcher: shared.Watcher = try .init("system_client_", io);
    defer watcher.deinit(io);
    try watcher.load(io);

    var system_context: system.Context = undefined;
    var system_table: system.ffi.Table = try .load(&watcher.dynlib.?);

    system_table.systemContextInit(&system_context, &system.Context.Data{
        .gpa = gpa,
        .asset_server = &asset_server,
        .platform = platform,
        .window = window,
        .io = io,
        .world = &world,
    });

    var elapsed_time: f32 = 0;
    var accumlated_time: f32 = 0;
    const time_step: f32 = 0.0167;
    main_loop: while (true) {
        steamPump(steam_pipe);

        accumlated_time += getDeltaTime(io);
        if (accumlated_time < time_step) continue;
        accumlated_time -= time_step;
        while (try window.poll(platform)) |event| {
            system_table.systemContextUpdate(&system_context, &.{ .delta_time = time_step, .elapsed_time = elapsed_time, .world = &world }, &event);
            switch (event) {
                .close => break :main_loop,
                .resize => |size| {
                    std.log.info("resize: {d}x{d}", .{ size.width, size.height });
                    try system_context.renderer.resize(gpa, window);
                },
                .key => |key| {
                    if (key.state == .released and key.sym == .escape) break :main_loop;
                    if (key.state == .released and key.sym == .f1) {
                        _ = Steam.SteamMatchmaking().RequestLobbyList();
                        std.log.info("requested lobby list", .{});
                    }
                    if (key.state == .released and key.sym == .f2) {
                        if (state.last_match != 0) {
                            _ = Steam.SteamMatchmaking().JoinLobby(state.last_match);
                            std.log.info("joining lobby {d}", .{state.last_match});
                        } else {
                            std.log.warn("F2: no lobby in last match list (press F1 first)", .{});
                        }
                    }
                    if (key.state == .released and key.sym == .f3) {
                        _ = Steam.SteamMatchmaking().CreateLobby(.k_ELobbyTypePublic, 4);
                        std.log.info("create lobby requested", .{});
                    }
                    if (key.state == .released and key.sym == .f4) {
                        const my_id = Steam.SteamUser().GetSteamID();
                        std.log.info("F4: self-connecting to {d} on virtual port {d}", .{ my_id, self_connect_virtual_port });
                        connectToServer(my_id, self_connect_virtual_port);
                    }
                },
                else => {},
            }
        }
        system_table.systemContextUpdate(&system_context, &.{ .delta_time = time_step, .elapsed_time = elapsed_time, .world = &world }, null);

        if (try watcher.reload(io)) {
            std.log.err("system table updated", .{});
            system_table.systemContextReload(&system_context, true);
            watcher.old_dynlib.?.close();
            watcher.old_dynlib = null;
            system_table = try .load(&watcher.dynlib.?);
            asset_server.deinit();
            asset_server = try shared.AssetServer.init(gpa, init.io);
            system_table.systemContextReload(&system_context, false);
        }

        elapsed_time += time_step;
    }

    system_table.systemContextDeinit(&system_context);
}

fn steamPump(pipe: Steam.HSteamPipe) void {
    Steam.SteamAPI_ManualDispatch_RunFrame(pipe);
    var msg: Steam.CallbackMsg_t = undefined;
    while (Steam.SteamAPI_ManualDispatch_GetNextCallback(pipe, &msg)) {
        defer Steam.SteamAPI_ManualDispatch_FreeLastCallback(pipe);
        const data = msg.data() orelse continue;
        switch (data) {
            .LobbyCreated => |ev| {
                std.log.info("lobby created: result={s} id={d}", .{ @tagName(ev.m_eResult), ev.m_ulSteamIDLobby });
                state.own_lobby = ev.m_ulSteamIDLobby;
                if (server_steamid != 0) {
                    var val_buf: [21]u8 = undefined;
                    const val = std.fmt.bufPrintZ(&val_buf, "{d}", .{server_steamid}) catch unreachable;
                    const key_lit = "server_steamid";
                    const ok = Steam.SteamMatchmaking().SetLobbyData(
                        ev.m_ulSteamIDLobby,
                        @ptrCast(key_lit),
                        @ptrCast(val.ptr),
                    );
                    std.log.info("SetLobbyData server_steamid={d} ok={}", .{ server_steamid, ok });
                }
            },
            .LobbyMatchList => |ev| {
                const mm = Steam.SteamMatchmaking();
                std.log.info("lobby list: {d} match(es)", .{ev.m_nLobbiesMatching});
                state.last_match = 0;
                var i: i32 = 0;
                while (i < @as(i32, @intCast(ev.m_nLobbiesMatching))) : (i += 1) {
                    const lobby_id = mm.GetLobbyByIndex(i);
                    const owner = mm.GetLobbyOwner(lobby_id);
                    std.log.info("  [{d}] lobby={d} owner={d}", .{ i, lobby_id, owner });
                    if (i == 0) state.last_match = lobby_id;
                }
            },
            .LobbyEnter => |ev| {
                const mm = Steam.SteamMatchmaking();
                const key_lit = "server_steamid";
                const c_val = mm.GetLobbyData(ev.m_ulSteamIDLobby, @ptrCast(key_lit));
                const val = std.mem.span(c_val);
                std.log.info("lobby enter: id={d} server_steamid=\"{s}\"", .{ ev.m_ulSteamIDLobby, val });
                const id = std.fmt.parseInt(u64, val, 10) catch 0;
                if (id != 0) connectToServer(id, 0);
            },
            .SteamNetConnectionStatusChangedCallback => |ev| {
                std.log.info("client net state: {s} (conn={d})", .{ @tagName(ev.m_info.m_eState), ev.m_hConn });
                switch (ev.m_info.m_eState) {
                    .k_ESteamNetworkingConnectionState_Connected => {
                        state.server_conn = ev.m_hConn;
                    },
                    .k_ESteamNetworkingConnectionState_ClosedByPeer,
                    .k_ESteamNetworkingConnectionState_ProblemDetectedLocally,
                    => {
                        _ = Steam.SteamNetworkingSockets_SteamAPI().CloseConnection(ev.m_hConn, 0, "client-close", false);
                        if (state.server_conn == ev.m_hConn) state.server_conn = 0;
                    },
                    else => {},
                }
            },
            else => {},
        }
    }
}

fn connectToServer(steam_id: u64, virtual_port: i32) void {
    var identity: Steam.SteamNetworkingIdentity = undefined;
    identity.Clear();
    identity.SetSteamID64(steam_id);
    const conn = Steam.SteamNetworkingSockets_SteamAPI().ConnectP2P(&identity, virtual_port, &.{});
    if (conn == 0) {
        std.log.err("ConnectP2P failed for {d} (vport={d})", .{ steam_id, virtual_port });
        return;
    }
    state.server_conn = conn;
    std.log.info("ConnectP2P({d}, vport={d}) -> {d}", .{ steam_id, virtual_port, conn });
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
