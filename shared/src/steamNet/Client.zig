const std = @import("std");
const steam = @import("steamworks");
const Packets = @import("../SteamNet.zig").Packets;
const ServerListResponse = steam.ISteamMatchmakingServerListResponse;

pub const ServerInfo = extern struct {
    steam_id: u64,
    name: [64]u8,
    id_str: [64]u8,
};
pub const ServerList = extern struct {
    const RefreshState = enum(u8) {
        idle,
        request,
        refreshing,
        done,
    };
    servers: [8]ServerInfo = undefined,
    count: usize = 0,
    refresh_state: RefreshState = .idle,
};

const Browser = extern struct {
    const VTable = extern struct {
        responded: *const fn (*Browser, steam.HServerListRequest, i32) callconv(.c) void,
        failed: *const fn (*Browser, steam.HServerListRequest, i32) callconv(.c) void,
        complete: *const fn (*Browser, steam.HServerListRequest, steam.EMatchMakingServerResponse) callconv(.c) void,
    };
    //NOTE: vtable_ptr only exist cuz of CPP BS.
    vtable: *const VTable = &.{
        .responded = &responded,
        .failed = &failed,
        .complete = &complete,
    },
    list: ServerList = .{},
    request: steam.HServerListRequest = 0,

    fn responded(_: *Browser, request: steam.HServerListRequest, server_index: i32) callconv(.c) void {
        const server = steam.SteamMatchmakingServers().GetServerDetails(request, server_index);
        std.log.info("Server[{d}] steamID={d} name=\"{s}\"", .{
            server_index, server.*.m_steamID, std.mem.sliceTo(server.*.m_szServerName[0..], 0),
        });
    }
    fn failed(_: *Browser, _: steam.HServerListRequest, server_index: i32) callconv(.c) void {
        std.log.info("Server[{d}] Failed to respond", .{
            server_index,
        });
    }
    fn complete(self: *Browser, request: steam.HServerListRequest, response: steam.EMatchMakingServerResponse) callconv(.c) void {
        std.log.info("server list refresh compele: {s}", .{@tagName(response)});
        const servers = steam.SteamMatchmakingServers();
        const server_count = servers.GetServerCount(request);
        std.log.info("refresh complete: {s} ({d} servers)", .{ @tagName(response), server_count });
        self.list.count = @max(@min(server_count, self.list.servers.len), 0);
        for (0..self.list.count) |server_index| {
            const server = servers.GetServerDetails(request, @intCast(server_index));
            self.list.servers[server_index].steam_id = server.*.m_steamID;
            @memcpy(self.list.servers[server_index].name[0..], server.*.m_szServerName[0..]);
            std.log.info("Server[{d}] steamID={d} hadResponse={} name=\"{s}\"", .{
                server_index,
                server.*.m_steamID,
                server.*.m_bHadSuccessfulResponse,
                std.mem.sliceTo(server.*.m_szServerName[0..], 0),
            });
        }
        self.list.refresh_state = .done;
    }
};

handle_packets_future: std.Io.Future(@typeInfo(@TypeOf(handlePackets)).@"fn".return_type.?),
packet_mutex: std.Io.Mutex = .init,

gpa: std.mem.Allocator,
io: std.Io,
server_conn: steam.HSteamNetConnection = 0,
own_lobby: u64 = 0,
packets: Packets,
pipe: steam.HSteamPipe,
browser: Browser,

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
        .browser = .{},
    };
}

pub fn deinit(self: *@This()) void {
    self.handle_packets_future.cancel(self.io) catch {};

    const servers = steam.SteamMatchmakingServers();
    if (self.browser.request != 0) {
        servers.CancelQuery(self.browser.request);
        servers.ReleaseRequest(self.browser.request);
        self.browser.request = 0;
    }
    self.closeConnection();

    //NOTE: drain or SteamAPI_Shutdown segfaults when a conn + server-list query both existed.
    var drained: u32 = 0;
    while (drained < 200) : (drained += 1) {
        self.steamPump() catch {};
        self.io.sleep(.fromMilliseconds(2), .real) catch {};
    }

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
        if (self.browser.list.refresh_state == .request) {
            self.browser.list.refresh_state = .refreshing;
            const servers = steam.SteamMatchmakingServers();
            const app_id = steam.SteamUtils().GetAppID();
            std.log.info("requsting internet server list for app {d}...", .{app_id});
            self.browser.request = servers.RequestInternetServerList(app_id, null, 0, @ptrCast(&self.browser));
        }
        self.packet_mutex.unlock(self.io);
        try self.io.sleep(.{ .nanoseconds = 1_000_000 }, .real);
    }
}

fn steamPump(self: *@This()) !void {
    steam.SteamAPI_ManualDispatch_RunFrame(self.pipe);
    if (self.browser.list.refresh_state == .done and self.browser.request != 0) {
        const servers = steam.SteamMatchmakingServers();
        servers.ReleaseRequest(self.browser.request);
        self.browser.request = 0;
    }

    var callback: steam.CallbackMsg_t = undefined;
    while (steam.SteamAPI_ManualDispatch_GetNextCallback(self.pipe, &callback)) {
        defer steam.SteamAPI_ManualDispatch_FreeLastCallback(self.pipe);
        const callback_data = callback.data() orelse continue;
        switch (callback_data) {
            .SteamNetConnectionStatusChangedCallback => |status_changed| {
                std.log.info("client net state: {s} (conn={d})", .{ @tagName(status_changed.m_info.m_eState), status_changed.m_hConn });
                switch (status_changed.m_info.m_eState) {
                    .k_ESteamNetworkingConnectionState_Connected => {
                        self.server_conn = status_changed.m_hConn;
                        try self.packets.pushEvent(self.gpa, .{ .connected = status_changed.m_hConn });
                    },
                    .k_ESteamNetworkingConnectionState_ClosedByPeer,
                    .k_ESteamNetworkingConnectionState_ProblemDetectedLocally,
                    => {
                        _ = steam.SteamNetworkingSockets_SteamAPI().CloseConnection(status_changed.m_hConn, 0, "client-close", false);
                        if (self.server_conn == status_changed.m_hConn) self.server_conn = 0;
                        try self.packets.pushEvent(self.gpa, .{ .disconnected = status_changed.m_hConn });
                    },
                    else => {},
                }
            },

            else => {},
        }
    }
}

pub fn recievePackets(self: *@This()) !void {
    const sockets = steam.SteamNetworkingSockets_SteamAPI();

    // var status: steam.SteamNetConnectionRealTimeStatus_t = std.mem.zeroes(steam.SteamNetConnectionRealTimeStatus_t);
    // const r = sock.GetConnectionRealTimeStatus(self.server_conn, &status, &.{});
    // if (r == .k_EResultOK) {
    //     std.log.info("ping={d}ms", .{status.m_nPing});
    // }

    var messages: [16][*c]steam.SteamNetworkingMessage_t = undefined;
    while (true) {
        const received = sockets.ReceiveMessagesOnConnection(self.server_conn, &messages[0], @intCast(messages.len));
        if (received <= 0) break;
        const received_count: usize = @intCast(received);
        for (messages[0..received_count]) |raw_message| {
            if (raw_message == null) continue;
            const message: *steam.SteamNetworkingMessage_t = raw_message;
            defer message.Release();
            if (message.m_pData == null or message.m_cbSize <= 0) continue;
            const bytes = message.m_pData[0..@intCast(message.m_cbSize)];
            try self.packets.pushIncoming(self.gpa, self.server_conn, bytes);
        }
    }
}

pub fn sendPackets(self: *@This()) !void {
    if (self.packets.outgoing.items.len == 0) return;
    const sockets = steam.SteamNetworkingSockets_SteamAPI();
    for (self.packets.outgoing.items) |*message| {
        var message_number: i64 = 0;
        _ = sockets.SendMessageToConnection(message.conn, message.bytes[0..message.len], @intFromEnum(message.flags), &message_number);
    }
    self.packets.outgoing.clearRetainingCapacity();
}

pub fn connectToServer(self: *@This(), steam_id: u64) !void {
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

pub fn closeConnection(self: *@This()) void {
    if (self.server_conn == 0) return;
    _ = steam.SteamNetworkingSockets_SteamAPI().CloseConnection(self.server_conn, 0, "client-shutdown", false);
    self.server_conn = 0;
}
