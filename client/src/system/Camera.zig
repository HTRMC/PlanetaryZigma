const std = @import("std");
const nz = @import("shared").numz;
const system = @import("../system.zig");
const shared = @import("shared");
const Info = system.Info;
const yes = @import("yes");

fov_rad: f32 = 1.5,
aspect: f32 = 0,
near: f32 = 0.1,
far: f32 = 1000,
speed: f32 = 5,
sensitivity: f32 = 1,
was_rotating: bool = false,
mouse_pos: [2]f64 = .{ 0, 0 },
mouse_prev_pos: [2]f64 = .{ 0, 0 },

input_map: shared.net.Command.Input = .{},

transform: nz.Transform3D(f32) = .{},

pub fn update(self: *@This(), info: *const Info) void {
    _ = info;

    self.input_map.mouse_delta[0] = self.mouse_pos[0] - self.mouse_prev_pos[0];
    self.input_map.mouse_delta[1] = self.mouse_pos[1] - self.mouse_prev_pos[1];
    self.mouse_prev_pos[0] = self.mouse_pos[0];
    self.mouse_prev_pos[1] = self.mouse_pos[1];

    // const world = info.world;
    // const current_pitch_rad = self.transform.rotation[0];
    // const current_yaw_rad = self.transform.rotation[1];
    //
    // camera.sensitivity = 1;
    // camera.speed = 500;

    // var relative_x: f32 = undefined;
    // var relative_y: f32 = undefined;
    // _ = sdl.SDL_GetRelativeMouseState(&relative_x, &relative_y);
    //
    //SDL_BUTTON_X1 works on Lucas machine for right click
    // if (mouse == sdl.SDL_BUTTON_RIGHT or mouse == sdl.SDL_BUTTON_X1) {
    //     if (!sdl.SDL_HideCursor()) return error.SdlHideCursor;
    //     current_yaw_rad += relative_x * camera.sensitivity * delta_time;
    //     current_pitch_rad -= relative_y * camera.sensitivity * delta_time;
    //     camera.was_rotating = true;
    // } else if (camera.was_rotating) {
    //     _ = sdl.SDL_GetRelativeMouseState(null, null);
    //     camera.was_rotating = false;
    //     if (!sdl.SDL_ShowCursor()) return error.SdlShowCursor;
    // }

    // current_pitch_rad = std.math.clamp(current_pitch_rad, -1.5, 1.5);
    // const forward = nz.vec.forwardFromEuler(nz.Vec3(f32){ current_pitch_rad, current_yaw_rad, 0 });
    //
    // const right = nz.vec.normalize(nz.vec.cross(forward, nz.Vec3(f32){ 0, 1, 0 }));
    //
    // const up = nz.vec.normalize(nz.vec.cross(right, forward));
    //
    // std.debug.print(
    //     \\--- Mouse / Orientation Debug ---
    //     \\mouse buttons: {x}
    //     \\rel mouse:     ({d:.2}, {d:.2})
    //     \\sensitivity:   {d:.3}
    //     \\yaw:          ({d:.3} rad)
    //     \\pitch:        ({d:.3} rad)
    //     \\forward:       ({d:.3}, {d:.3}, {d:.3})
    //     \\right:         ({d:.3}, {d:.3}, {d:.3})
    //     \\up:            ({d:.3}, {d:.3}, {d:.3})
    //     \\---------------------------------
    //     \\
    // ,
    //     .{
    //         mouse,
    //         relative_x,
    //         relative_y,
    //         camera.sensitivity,
    //         yaw_rad.*,
    //         pitch_rad.*,
    //         forward[0],
    //         forward[1],
    //         forward[2],
    //         right[0],
    //         right[1],
    //         right[2],
    //         up[0],
    //         up[1],
    //         up[2],
    //     },
    // );

    // var move = nz.Vec3(f32){ 0, 0, 0 };
    // const velocity = self.speed * info.delta_time;
    // std.log.debug("dt: {d}", .{info.delta_time});

    // if (self.input_map.forward)
    //     move += nz.vec.scale(forward, velocity);
    // if (self.input_map.backward)
    //     move -= nz.vec.scale(forward, velocity);
    // if (self.input_map.left)
    //     move -= nz.vec.scale(right, velocity);
    // if (self.input_map.right)
    //     move += nz.vec.scale(right, velocity);
    // if (self.input_map.down)
    //     move += nz.vec.scale(up, velocity);
    // if (self.input_map.up)
    //     move -= nz.vec.scale(up, velocity);
    //
    // if (keyboard[sdl.SDL_SCANCODE_SPACE])
    //     move += nz.vec.scale(up, velocity);
    //
    // if (keyboard[sdl.SDL_SCANCODE_UP])
    //     camera.speed += 10;
    // if (keyboard[sdl.SDL_SCANCODE_DOWN])
    //     camera.speed -= 10;
    self.speed = std.math.clamp(self.speed, 0, 1000);

    // const speed_multiplier: f32 = if (keyboard[sdl.SDL_SCANCODE_LSHIFT]) 3 else 1;
    // move = nz.vec.scale(move, speed_multiplier);
    // self.transform.position += move;
    // std.log.debug("pos {any}", .{self.transform.position});
    // std.log.debug("speed {any}", .{self.speed});
}

pub fn eventUpdate(self: *@This(), info: *const Info, event: *const yes.Window.Event) !void {
    _ = info;

    switch (event.*) {
        .key => |key| {
            // std.log.debug("pressed", .{});

            const pressed = key.state == .pressed;
            switch (key.sym) {
                .w => self.input_map.forward = pressed,
                .s => self.input_map.backward = pressed,
                .d => self.input_map.right = pressed,
                .a => self.input_map.left = pressed,
                .q => self.input_map.down = pressed,
                .e => self.input_map.up = pressed,
                .r => self.input_map.r = pressed,
                .k => self.input_map.k = pressed,
                else => {},
            }
        },
        .mouse_scroll => switch (event.mouse_scroll) {
            .vertical => |scroll| {
                self.input_map.mouse_wheel = scroll;
            },
            .horizontal => {},
        },
        .focus => |focused| {
            if (!focused) self.input_map = .{};
        },
        .mouse_motion => |motion| {
            self.mouse_pos[0] = motion.x;
            self.mouse_pos[1] = motion.y;
        },
        .mouse_button => |button| {
            if (button.state == .pressed and button.button == .left)
                self.input_map.mouse_button_left = true
            else if (button.state == .released and button.button == .left) {
                self.input_map.mouse_button_left = false;
            }
            if (button.state == .pressed and button.button == .right)
                self.input_map.mouse_button_right = true
            else if (button.state == .released and button.button == .right) {
                self.input_map.mouse_button_right = false;
            }
        },

        else => {},
    }
}
