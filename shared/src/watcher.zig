const std = @import("std");
const builtin = @import("builtin");

dynlib: ?std.DynLib = null,
old_dynlib: ?std.DynLib = null,
dir_path: []const u8,
mtime: std.Io.Timestamp,
lib_name: []const u8,

pub fn init(comptime library_name: []const u8, io: std.Io) !@This() {
    const lib_name = "lib" ++ library_name;
    const search_paths: []const [:0]const u8 = &.{
        "../lib/",
        "zig-out/lib/",
        "client/zig-out/lib/",
        "./",
    };
    const found_path: []const u8 = path: for (search_paths) |path| {
        std.Io.Dir.cwd().access(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };

        const dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (std.mem.startsWith(u8, entry.name, lib_name)) break :path path;
        }
    } else return error.NoLibraryPathFound;

    return .{
        .dir_path = found_path,
        .mtime = .zero,
        .lib_name = lib_name,
    };
}

pub fn deinit(self: *@This(), io: std.Io) void {
    _ = io;
    if (self.dynlib) |*dynlib| dynlib.close();
    if (self.old_dynlib) |*dynlib| dynlib.close();
}

pub fn load(self: *@This(), io: std.Io) !void {
    const dir = try std.Io.Dir.cwd().openDir(io, self.dir_path, .{ .iterate = true });
    defer dir.close(io);

    var it = dir.iterate();
    std.log.debug("LIBNAME: {s}", .{self.lib_name});
    const file_name = while (try it.next(io)) |entry| {
        std.log.debug("FILE_NAME: {s}", .{entry.name});
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, self.lib_name)) continue;
        break entry.name;
    } else return error.FileNotFound;
    var full_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const full_path = try std.fmt.bufPrint(&full_path_buffer, "{s}{s}", .{ self.dir_path, file_name });
    std.log.debug("Full path: {s}", .{full_path});
    self.dynlib = std.DynLib.open(full_path) catch |err| {
        std.log.debug("Retry {}/{}: failed to open library: {}", .{ 1, 2, err });
        return err;
    };

    _ = self.dynlib.?.lookup(*const fn () void, "systemContextInit") orelse {
        std.log.debug("Retry {}/{}: library opened but symbols not available yet", .{ 1, 2 });
        self.dynlib.?.close();
        return error.TestSymbolLookup;
    };
    self.mtime = .now(io, .real);
}

pub fn reload(self: *@This(), io: std.Io) !bool {
    const dir = std.Io.Dir.cwd().openDir(io, self.dir_path, .{ .iterate = true }) catch return false;
    defer dir.close(io);
    const dir_stat = try dir.stat(io);
    if (dir_stat.mtime.nanoseconds <= self.mtime.nanoseconds) return false;

    self.old_dynlib = self.dynlib;
    self.load(io) catch {
        self.dynlib = self.old_dynlib;
        return false;
    };

    self.mtime = dir_stat.mtime;
    self.mtime.nanoseconds += std.time.ns_per_s * 2;

    std.log.debug("Reloaded dynamic lib:\n, PATH {s}\n", .{self.lib_name});
    return true;
}

pub inline fn lookup(self: *@This(), comptime T: type, name: [:0]const u8) !T {
    const function_pointer = self.dynlib.?.lookup(T, name);
    if (function_pointer == null) return error.DynlibLookup;
    return function_pointer.?;
}
