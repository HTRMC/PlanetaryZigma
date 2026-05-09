//! Layout-stable shim between main.zig (which owns the Steam runtime state)
//! and the hot-reloadable system dynlib (which only does game logic).
//!
//! main.zig drives the Steam side: pumps callbacks, drains
//! ReceiveMessagesOnConnection into `incoming`, surfaces connect/disconnect
//! via `events`, and flushes `outgoing` through SendMessageToConnection.
//!
//! NetworkManager (inside the dynlib) reads `events` and `incoming`, parses
//! Commands, processes them, and pushes responses into `outgoing`. It never
//! touches Steam types directly.

const std = @import("std");
const steam = @import("steamworks");

/// Mirrors steam.HSteamNetConnection (u32). Defined locally so the dynlib
/// doesn't need to import the steamworks package.
pub const Conn = u32;

pub const max_msg_bytes: usize = 1024;

pub const Message = struct {
    conn: Conn,
    len: u32,
    bytes: [max_msg_bytes]u8 = undefined,

    pub fn slice(self: *const Message) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const Event = union(enum) {
    connected: Conn,
    disconnected: Conn,
};

const Packets = struct {
    incoming: std.ArrayListUnmanaged(Message) = .empty,
    outgoing: std.ArrayListUnmanaged(Message) = .empty,
    events: std.ArrayListUnmanaged(Event) = .empty,

    pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
        self.incoming.deinit(gpa);
        self.outgoing.deinit(gpa);
        self.events.deinit(gpa);
    }

    pub fn pushIncoming(self: *@This(), gpa: std.mem.Allocator, conn: Conn, bytes: []const u8) !void {
        const len: u32 = @intCast(@min(bytes.len, max_msg_bytes));
        var msg: Message = .{ .conn = conn, .len = len };
        @memcpy(msg.bytes[0..len], bytes[0..len]);
        try self.incoming.append(gpa, msg);
    }

    pub fn pushOutgoing(self: *@This(), gpa: std.mem.Allocator, conn: Conn, bytes: []const u8) !void {
        const len: u32 = @intCast(@min(bytes.len, max_msg_bytes));
        var msg: Message = .{ .conn = conn, .len = len };
        @memcpy(msg.bytes[0..len], bytes[0..len]);
        try self.outgoing.append(gpa, msg);
    }

    pub fn pushEvent(self: *@This(), gpa: std.mem.Allocator, event: Event) !void {
        try self.events.append(gpa, event);
    }
};

pub const Server = struct {
    pub const max_connections: usize = 32;
    connections: [max_connections]steam.HSteamNetConnection = @splat(0),

    gpa: std.mem.Allocator,
    pipe: steam.HSteamPipe,
    gs: steam.ISteamGameServer,
    socket: steam.ISteamNetworkingSockets,
    packets: Packets,

    pub fn init(gpa: std.mem.Allocator, io: std.Io) !@This() {
        if (!steam.Server.SteamInternal_GameServer_Init(
            0,
            27016,
            27015,
            steam.STEAMGAMESERVER_QUERY_PORT_SHARED,
            steam.EServerMode.eServerModeAuthentication,
            "1.0.0.0",
        )) @panic("failed to init steam game server");

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
            switch (try steamCallback(null, gpa, pipe, null)) {
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

        return .{
            .gpa = gpa,
            .pipe = pipe,
            .gs = gs,
            .socket = sock,
            .packets = .{},
        };
    }

    pub fn deinit(self: @This()) void {
        _ = self;
        steam.Server.SteamGameServer_Shutdown();

        // self.packets.deinit(self.gpa);
    }

    pub fn recievePackets(self: *@This()) !void {
        _ = try self.steamCallback(self.gpa, self.pipe, self.socket);
        var msgs: [16][*c]steam.SteamNetworkingMessage_t = undefined;
        for (self.connections) |conn| {
            if (conn == 0) continue;
            const n = self.socket.ReceiveMessagesOnConnection(conn, &msgs[0], @intCast(msgs.len));
            if (n <= 0) continue;
            const cnt: usize = @intCast(n);
            for (msgs[0..cnt]) |raw| {
                if (raw == null) continue;
                const m: *steam.SteamNetworkingMessage_t = raw;
                defer m.Release();
                if (m.m_pData == null or m.m_cbSize <= 0) continue;
                const bytes = m.m_pData[0..@intCast(m.m_cbSize)];
                try self.packets.pushIncoming(self.gpa, conn, bytes);
            }
        }
    }

    pub fn sendPackets(self: *@This()) !void {
        if (self.packets.outgoing.items.len == 0) return;
        for (self.packets.outgoing.items) |*msg| {
            var msg_num: i64 = 0;
            _ = self.socket.SendMessageToConnection(msg.conn, msg.bytes[0..msg.len], steam.k_nSteamNetworkingSend_Reliable, &msg_num);
        }
        self.packets.outgoing.clearRetainingCapacity();
    }

    fn steamCallback(
        self: ?*@This(),
        gpa: std.mem.Allocator,
        pipe: steam.HSteamPipe,
        sock: ?steam.ISteamNetworkingSockets,
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
                            self.?.addConnection(ev.m_hConn);
                            try self.?.packets.pushEvent(gpa, .{ .connected = ev.m_hConn });
                        },
                        .k_ESteamNetworkingConnectionState_ClosedByPeer,
                        .k_ESteamNetworkingConnectionState_ProblemDetectedLocally,
                        => {
                            if (sock) |s| _ = s.CloseConnection(ev.m_hConn, 0, "peer-closed", false);
                            self.?.removeConnection(ev.m_hConn);
                            try self.?.packets.pushEvent(gpa, .{ .disconnected = ev.m_hConn });
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

    fn addConnection(self: *@This(), conn: steam.HSteamNetConnection) void {
        for (&self.connections) |*slot| {
            if (slot.* == 0) {
                slot.* = conn;
                return;
            }
        }
        std.log.err("connection table full; dropping conn={d}", .{conn});
    }

    fn removeConnection(self: *@This(), conn: steam.HSteamNetConnection) void {
        for (&self.connections) |*slot| {
            if (slot.* == conn) {
                slot.* = 0;
                return;
            }
        }
    }
};

pub const Client = struct {
    gpa: std.mem.Allocator,
    server_conn: steam.HSteamNetConnection = 0,
    own_lobby: u64 = 0,
    packets: Packets,
    pipe: steam.HSteamPipe,
    // const State = struct {
    //     /// Steam lobby we created on startup (so we can write server_steamid into its data).
    //     own_lobby: u64 = 0,
    //     /// First lobby returned by the most recent RequestLobbyList; F2 will JoinLobby on it.
    //     last_match: u64 = 0,
    //     /// Active P2P connection to the server, if any.
    //     server_conn: steam.HSteamNetConnection = 0,
    // };
    //
    // var state: State = .{};

    pub fn init(gpa: std.mem.Allocator) !@This() {
        if (!steam.SteamAPI_Init()) return error.InitSteamworks;
        steam.SteamAPI_ManualDispatch_Init();
        const steam_pipe = steam.SteamAPI_GetHSteamPipe();
        return .{
            .pipe = steam_pipe,
            .packets = .{},
            .gpa = gpa,
        };
    }

    pub fn deinit(self: *@This()) void {
        steam.SteamAPI_Shutdown();
        self.packets.deinit(self.gpa);
    }

    fn steamPump(self: *@This()) !void {
        steam.SteamAPI_ManualDispatch_RunFrame(self.pipe);
        var msg: steam.CallbackMsg_t = undefined;
        while (steam.SteamAPI_ManualDispatch_GetNextCallback(self.pipe, &msg)) {
            defer steam.SteamAPI_ManualDispatch_FreeLastCallback(self.pipe);
            const data = msg.data() orelse continue;
            switch (data) {
                .SteamNetConnectionStatusChangedCallback => |ev| {
                    std.log.info("client net state: {s} (conn={d})", .{ @tagName(ev.m_info.m_eState), ev.m_hConn });
                    switch (ev.m_info.m_eState) {
                        .k_ESteamNetworkingConnectionState_Connected => {
                            self.server_conn = ev.m_hConn;
                            try self.packets.pushEvent(self.gpa, .{ .connected = ev.m_hConn });
                        },
                        .k_ESteamNetworkingConnectionState_ClosedByPeer,
                        .k_ESteamNetworkingConnectionState_ProblemDetectedLocally,
                        => {
                            _ = steam.SteamNetworkingSockets_SteamAPI().CloseConnection(ev.m_hConn, 0, "client-close", false);
                            if (self.server_conn == ev.m_hConn) self.server_conn = 0;
                            try self.packets.pushEvent(self.gpa, .{ .disconnected = ev.m_hConn });
                        },
                        else => {},
                    }
                },
                else => {},
            }
        }
    }

    pub fn recievePackets(self: *@This()) !void {
        const sock = steam.SteamNetworkingSockets_SteamAPI();

        var status: steam.SteamNetConnectionRealTimeStatus_t = std.mem.zeroes(steam.SteamNetConnectionRealTimeStatus_t);
        const r = sock.GetConnectionRealTimeStatus(self.server_conn, &status, &.{});
        if (r == .k_EResultOK) {
            std.log.info("ping={d}ms", .{status.m_nPing});
        }

        try self.steamPump();
        var msgs: [16][*c]steam.SteamNetworkingMessage_t = undefined;
        const n = sock.ReceiveMessagesOnConnection(self.server_conn, &msgs[0], @intCast(msgs.len));
        if (n <= 0) return;
        const count: usize = @intCast(n);
        for (msgs[0..count]) |raw| {
            if (raw == null) continue;
            const m: *steam.SteamNetworkingMessage_t = raw;
            defer m.Release();
            if (m.m_pData == null or m.m_cbSize <= 0) continue;
            const bytes = m.m_pData[0..@intCast(m.m_cbSize)];
            try self.packets.pushIncoming(self.gpa, self.server_conn, bytes);
        }
    }

    pub fn sendPackets(self: *@This()) !void {
        if (self.packets.outgoing.items.len == 0) return;
        const sock = steam.SteamNetworkingSockets_SteamAPI();
        for (self.packets.outgoing.items) |*msg| {
            var msg_num: i64 = 0;
            _ = sock.SendMessageToConnection(msg.conn, msg.bytes[0..msg.len], steam.k_nSteamNetworkingSend_Reliable, &msg_num);
        }
        self.packets.outgoing.clearRetainingCapacity();
    }

    pub fn connectToServer(self: *@This(), steam_id: u64) void {
        var identity: steam.SteamNetworkingIdentity = undefined;
        identity.Clear();
        identity.SetSteamID64(steam_id);
        const conn = steam.SteamNetworkingSockets_SteamAPI().ConnectP2P(&identity, 0, &.{});
        if (conn == 0) {
            std.log.err("ConnectP2P failed for {d}", .{steam_id});
            return;
        }
        self.server_conn = conn;
        std.log.info("ConnectP2P({d}) -> {d}", .{ steam_id, conn });
    }
};
