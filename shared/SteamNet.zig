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

const Self = @This();

incoming: std.ArrayListUnmanaged(Message) = .empty,
outgoing: std.ArrayListUnmanaged(Message) = .empty,
events: std.ArrayListUnmanaged(Event) = .empty,

pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
    self.incoming.deinit(gpa);
    self.outgoing.deinit(gpa);
    self.events.deinit(gpa);
}

pub fn pushIncoming(self: *Self, gpa: std.mem.Allocator, conn: Conn, bytes: []const u8) !void {
    const len: u32 = @intCast(@min(bytes.len, max_msg_bytes));
    var msg: Message = .{ .conn = conn, .len = len };
    @memcpy(msg.bytes[0..len], bytes[0..len]);
    try self.incoming.append(gpa, msg);
}

pub fn pushOutgoing(self: *Self, gpa: std.mem.Allocator, conn: Conn, bytes: []const u8) !void {
    const len: u32 = @intCast(@min(bytes.len, max_msg_bytes));
    var msg: Message = .{ .conn = conn, .len = len };
    @memcpy(msg.bytes[0..len], bytes[0..len]);
    try self.outgoing.append(gpa, msg);
}

pub fn pushEvent(self: *Self, gpa: std.mem.Allocator, event: Event) !void {
    try self.events.append(gpa, event);
}
