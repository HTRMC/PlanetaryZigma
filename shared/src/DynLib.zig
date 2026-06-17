const std = @import("std");
const builtin = @import("builtin");
const tracy = @import("ztracy");

const Backend = switch (builtin.os.tag) {
    .windows => WindowsDynLib,
    else => std.DynLib,
};

pub const DynLib = struct {
    backend: Backend,

    pub fn open(path: []const u8) !@This() {
        const tracy_scope = tracy.zone(@src());
        defer tracy_scope.end();
        return .{ .backend = try Backend.open(path) };
    }

    pub fn close(self: *@This()) void {
        const tracy_scope = tracy.zone(@src());
        defer tracy_scope.end();
        self.backend.close();
    }

    pub fn lookup(self: *@This(), comptime T: type, name: [:0]const u8) ?T {
        const tracy_scope = tracy.zone(@src());
        defer tracy_scope.end();
        return self.backend.lookup(T, name);
    }
};

const WindowsDynLib = struct {
    handle: std.os.windows.HMODULE,

    extern "kernel32" fn LoadLibraryW(path: [*:0]const u16) callconv(.winapi) ?std.os.windows.HMODULE;
    extern "kernel32" fn GetProcAddress(module: std.os.windows.HMODULE, name: [*:0]const u8) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn FreeLibrary(module: std.os.windows.HMODULE) callconv(.winapi) std.os.windows.BOOL;

    fn open(path: []const u8) !WindowsDynLib {
        const tracy_scope = tracy.zone(@src());
        defer tracy_scope.end();
        var buf: [std.fs.max_path_bytes]u16 = undefined;
        const len = try std.unicode.utf8ToUtf16Le(buf[0 .. buf.len - 1], path);
        buf[len] = 0;
        const handle = LoadLibraryW(buf[0..len :0].ptr) orelse return error.FileNotFound;
        return .{ .handle = handle };
    }

    fn close(self: *WindowsDynLib) void {
        const tracy_scope = tracy.zone(@src());
        defer tracy_scope.end();
        _ = FreeLibrary(self.handle);
        self.* = undefined;
    }

    fn lookup(self: *WindowsDynLib, comptime T: type, name: [:0]const u8) ?T {
        const tracy_scope = tracy.zone(@src());
        defer tracy_scope.end();
        return @ptrCast(GetProcAddress(self.handle, name.ptr) orelse return null);
    }
};
