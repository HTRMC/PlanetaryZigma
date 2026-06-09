const std = @import("std");
const nz = @import("shared").numz;
const system = @import("../system.zig");
const shared = @import("shared");
const Info = system.Info;
const yes = @import("yes");
const Ui = @import("../Renderer/Vulkan/Ui.zig");

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

pub fn update(self: *@This(), info: *const Info, ui: *Ui) void {
    _ = info;

    self.input_map.mouse_delta[0] = self.mouse_pos[0] - self.mouse_prev_pos[0];
    self.input_map.mouse_delta[1] = self.mouse_pos[1] - self.mouse_prev_pos[1];
    self.mouse_prev_pos[0] = self.mouse_pos[0];
    self.mouse_prev_pos[1] = self.mouse_pos[1];

    const pos: [2]f32 = .{ @floatCast(self.mouse_pos[0]), @floatCast(self.mouse_pos[1]) };
    ui.start(.{
        .position = .{ .left = pos[0], .top = pos[1] },
        .left_click = self.input_map.mouse_button_left,
        .right_click = self.input_map.mouse_button_right,
    });
    const root = ui.add(null, null, .{
        .size = if (ui.isHot("button")) .{
            .heigth = 200,
            .width = 200,
        } else .{
            .heigth = 100,
            .width = 100,
        },
        .position = .center,
        .color = .new(1, 0, 0, 1),
    });
    _ = ui.add(root, null, .{
        .position = .center,
        .size = .{ .heigth = 30, .width = 10 },
    });
    _ = ui.add(root, "button", .{
        .position = .center,
        .size = .{ .heigth = 10, .width = 10 },
        .color = if (ui.isHot("button")) .new(0, 1, 0, 1) else .new(0, 0, 1, 1),
    });

    if (ui.isActive("button")) {
        _ = ui.add(null, null, .{
            .position = .{
                .fixed = .{
                    .left = 10,
                    .top = 10,
                },
            },
            .size = .{ .heigth = 100, .width = 100 },
        });
    }
    ui.end();
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
