const std = @import("std");
const builtin = @import("builtin");
const shared = @import("shared");
const system = @import("system");
const World = system.World;
const yes = @import("yes");
const tracy = @import("ztracy");
const miniaudio = @import("miniaudio");

// Sound asset peak targets:
// UI click / inventory: -24 to -18 dBFS; footsteps / cloth: -20 to -14 dBFS.
// Regular weapon / magic zap: -14 to -9 dBFS; heavy attack / explosion: -10 to -6 dBFS.
// Boss roar / death growl: -7 to -3 dBFS; master output peak: around -1 dBFS.
const master_output_gain_db: f32 = -1.0;
const boss_death_sound = "sounds/boss/death_growl.ogg";
const bullet_shoot_sound = "sounds/weapons/bullet_shoot.ogg";
const enemy_death_sound = "sounds/enemy/death_flesh.ogg";
const item_pickup_sound = "sounds/items/pickup_item.ogg";
const lootbox_open_sound = "sounds/lootbox/open.ogg";
const teleported_charged_sound = "sounds/monolith/teleported_charged.ogg";
const lightning_attack_sounds = [_][]const u8{
    "sounds/lightning/combo_01.ogg",
    "sounds/lightning/combo_02.ogg",
    "sounds/lightning/combo_03.ogg",
    "sounds/lightning/combo_04.ogg",
    "sounds/lightning/combo_05.ogg",
    "sounds/lightning/combo_06.ogg",
};

pub fn main(init: std.process.Init) !void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();
    tracy.setThreadName("main");
    const startup_zone = tracy.zoneNamed(@src(), "Startup");
    var gpa_impl = if (builtin.mode == .Debug) std.heap.DebugAllocator(.{ .stack_trace_frames = 16, .verbose_log = false }).init else init.gpa;
    defer {
        if (builtin.mode == .Debug) _ = gpa_impl.deinit();
    }
    const gpa = if (builtin.mode == .Debug) gpa_impl.allocator() else gpa_impl;
    const io = init.io;

    var eng: miniaudio.ma_engine = undefined;
    if (miniaudio.ma_engine_init(null, &eng) != miniaudio.MA_SUCCESS) return error.MiniaudioFailed;
    defer miniaudio.ma_engine_uninit(&eng);
    if (miniaudio.ma_engine_set_volume(&eng, dbToGain(master_output_gain_db)) != miniaudio.MA_SUCCESS) return error.MiniaudioFailed;
    // _ = miniaudio.ma_engine_play_sound(&eng, "music.mp3", null);

    if (builtin.mode != .Debug) shared.redirectStderrToFile(io, "client.log");

    const steam_zone = tracy.zoneNamed(@src(), "SteamInit");
    shared.SteamNet.log_connection_status = init.environ_map.contains("NET");
    std.log.info("\n====\nNET = {s}\n====\n", .{if (shared.SteamNet.log_connection_status) "TRUE" else "FALSE"});
    var steam_client: shared.SteamNet.Client = try .init(gpa, io);
    steam_client.handle_packets_future = try io.concurrent(shared.SteamNet.Client.handlePackets, .{&steam_client});
    steam_zone.end();

    defer steam_client.deinit();

    var cross_desktop: yes.Desktop.Cross = try .init(gpa, io, init.minimal);
    defer cross_desktop.deinit();
    const desktop = cross_desktop.desktop();

    var cross_window: yes.Desktop.Cross.Window = .empty(desktop);
    const window = cross_window.interface(desktop);
    const window_size: yes.Window.Size = .{ .width = 854, .height = 480 };
    const window_zone = tracy.zoneNamed(@src(), "WindowOpen");
    try window.open(desktop, .{
        .title = "PlanetaryZigma",
        .size = window_size,
        .resize_policy = .{ .specified = .{
            .min_size = .{ .width = 300, .height = 200 },
        } },
        .surface_type = .vulkan,
    });
    window_zone.end();
    defer window.close(desktop);

    var asset_server = try system.AssetServer.init(gpa, init.io);
    defer asset_server.deinit();

    var world: World = try .init(gpa);
    defer world.deinit();

    var watcher: shared.Watcher = try .init("system_client", io);
    defer watcher.deinit(io);
    try watcher.load(io);

    var system_context: system.Context = undefined;
    var system_table: system.ffi.Table = try .load(&watcher.dynlib.?);

    const ctx_zone = tracy.zoneNamed(@src(), "SystemContextInit");
    system_table.systemContextInit(&system_context, &system.Context.Data{
        .gpa = gpa,
        .asset_server = &asset_server,
        .desktop = desktop,
        .window = window,
        .io = io,
        .world = &world,
        .steam_client = &steam_client,
    });
    ctx_zone.end();
    defer system_table.systemContextDeinit(&system_context);

    var elapsed_time: f32 = 0;
    var accumlated_time: f32 = 0;
    const time_step: f32 = shared.tick_seconds;
    startup_zone.end();
    main_loop: while (true) {
        tracy.frameMark();
        const delta_time = getDeltaTime(io);
        if (delta_time > 0.1) std.log.warn("main loop stalled {d:.0}ms", .{delta_time * 1000});
        accumlated_time += delta_time;
        if (accumlated_time < time_step) {
            std.Io.sleep(io, .fromMilliseconds(1), .awake) catch {};
            continue;
        }
        accumlated_time -= time_step;
        while (try window.poll(desktop)) |event| {
            const options_was_open = system_context.hud.overlay == .options;
            system_table.systemContextUpdate(&system_context, &.{ .delta_time = time_step, .elapsed_time = elapsed_time, .world = &world }, &event);
            drainAudioCommands(&world, &asset_server, &eng);
            switch (event) {
                .close => break :main_loop,
                .resize => {
                    try system_context.renderer.resize(gpa, window);
                    system_context.ui.screen_width = @floatFromInt(window.size.width);
                    system_context.ui.screen_heigth = @floatFromInt(window.size.height);
                },
                .key => |key| {
                    if (key.state == .released and key.sym == .escape and system_context.scene != .game and !options_was_open) break :main_loop;
                    if (key.state == .released) {
                        // numpad 0-9 toggles to that ring slot's lib version (contiguous enum values)
                        const np0 = @intFromEnum(yes.Window.Event.Key.Sym.numpad_0);
                        const sym = @intFromEnum(key.sym);
                        if (sym >= np0 and sym < np0 + 10) {
                            if (watcher.version(sym - np0)) |lib| {
                                system_table.systemContextReload(&system_context, true);
                                system_table = try .load(lib);
                                system_table.systemContextReload(&system_context, false);
                                std.log.err("switched to version slot {d}", .{sym - np0});
                            }
                        }
                    }
                },
                else => {},
            }
            if (system_context.request_exit) break :main_loop;
        }
        system_table.systemContextUpdate(&system_context, &.{ .delta_time = time_step, .elapsed_time = elapsed_time, .world = &world }, null);
        drainAudioCommands(&world, &asset_server, &eng);
        if (system_context.request_exit) break :main_loop;

        if (try watcher.reload(io)) {
            std.log.err("system table updated", .{});
            system_table.systemContextReload(&system_context, true);
            system_table = try .load(&watcher.dynlib.?);
            system_table.systemContextReload(&system_context, false);
        }

        elapsed_time += time_step;
    }
}

fn drainAudioCommands(world: *World, asset_server: *const system.AssetServer, engine: *miniaudio.ma_engine) void {
    for (world.audio_outbox.items) |command| {
        switch (command) {
            .boss_death => _ = playSound(asset_server, engine, boss_death_sound),
            .bullet_shoot => _ = playSound(asset_server, engine, bullet_shoot_sound),
            .enemy_death => _ = playSound(asset_server, engine, enemy_death_sound),
            .item_pickup => _ = playSound(asset_server, engine, item_pickup_sound),
            .lightning_attack => _ = playSound(asset_server, engine, randomSound(world, lightning_attack_sounds[0..])),
            .lootbox_open => _ = playSound(asset_server, engine, lootbox_open_sound),
            .teleported_charged => _ = playSound(asset_server, engine, teleported_charged_sound),
        }
    }
    world.audio_outbox.clearRetainingCapacity();
}

fn dbToGain(db: f32) f32 {
    return std.math.pow(f32, 10.0, db / 20.0);
}

fn randomSound(world: *World, sounds: []const []const u8) []const u8 {
    return sounds[world.prng.random().uintLessThan(usize, sounds.len)];
}

fn playSound(asset_server: *const system.AssetServer, engine: *miniaudio.ma_engine, asset_path: []const u8) bool {
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = asset_server.dir.realPathFile(asset_server.io, asset_path, &path_buffer) catch |err| {
        std.log.warn("sound not found {s}/{s}: {t}", .{ asset_server.assets_path, asset_path, err });
        return false;
    };
    if (path_len >= path_buffer.len) {
        std.log.warn("sound path too long for {s}/{s}", .{ asset_server.assets_path, asset_path });
        return false;
    }
    path_buffer[path_len] = 0;
    const path = path_buffer[0..path_len :0];
    const result = miniaudio.ma_engine_play_sound(engine, path.ptr, null);
    if (result != miniaudio.MA_SUCCESS) {
        std.log.warn("play sound failed {s}: {d}", .{ path, result });
        return false;
    }
    return true;
}

pub fn getDeltaTime(io: std.Io) f32 {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();
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
