const std = @import("std");
const steam = @import("steamworks");
const Packets = @import("../SteamNet.zig").Packets;

handle_packets_future: std.Io.Future(@typeInfo(@TypeOf(handlePackets)).@"fn".return_type.?),
packet_mutex: std.Io.Mutex = .init,

gpa: std.mem.Allocator,
io: std.Io,
server_conn: steam.HSteamNetConnection = 0,
own_lobby: u64 = 0,
packets: Packets,
pipe: steam.HSteamPipe,

pub fn init(gpa: std.mem.Allocator, io: std.Io) !@This() {
    if (!steam.SteamAPI_Init()) return error.InitSteamworks;
    steam.SteamAPI_ManualDispatch_Init();
    const steam_pipe = steam.SteamAPI_GetHSteamPipe();
    return .{
        .pipe = steam_pipe,
        .packets = .{},
        .gpa = gpa,
        .handle_packets_future = undefined,
        .io = io,
    };
}

pub fn deinit(self: *@This()) void {
    steam.SteamAPI_Shutdown();
    self.packets.deinit(self.gpa);
}

pub fn handlePackets(self: *@This()) !void {
    while (true) {
        try self.io.checkCancel();
        try self.packet_mutex.lock(self.io);
        try self.steamPump();
        try self.recievePackets();
        try self.sendPackets();
        self.packet_mutex.unlock(self.io);
        try self.io.sleep(.{ .nanoseconds = 1_000_000 }, .real);
    }
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

    // var status: steam.SteamNetConnectionRealTimeStatus_t = std.mem.zeroes(steam.SteamNetConnectionRealTimeStatus_t);
    // const r = sock.GetConnectionRealTimeStatus(self.server_conn, &status, &.{});
    // if (r == .k_EResultOK) {
    //     std.log.info("ping={d}ms", .{status.m_nPing});
    // }

    var msgs: [16][*c]steam.SteamNetworkingMessage_t = undefined;
    while (true) {
        const n = sock.ReceiveMessagesOnConnection(self.server_conn, &msgs[0], @intCast(msgs.len));
        if (n <= 0) break;
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
}

pub fn sendPackets(self: *@This()) !void {
    if (self.packets.outgoing.items.len == 0) return;
    const sock = steam.SteamNetworkingSockets_SteamAPI();
    for (self.packets.outgoing.items) |*msg| {
        var msg_num: i64 = 0;
        _ = sock.SendMessageToConnection(msg.conn, msg.bytes[0..msg.len], @intFromEnum(msg.flags), &msg_num);
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
