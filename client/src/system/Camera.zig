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
    // if (true) return;
    ui.add(null, .{ .position = .{
        .fixed = .{
            .left = 0,
            .top = 40,
        },
    }, .size = .{
        .fixed = .{
            .heigth = 40,
            .width = 100,
        },
    }, .color = if (ui.isHot("refresh")) .new(1, 1, 1, 1) else .grey, .name = "refresh", .text = "Refresh" });

    if (ui.isActive("refresh")) {
        std.log.debug("Pressed button", .{});
    }

    ui.add(null, .{
        .name = "panel",
        .size = .{ .fixed = .{
            .heigth = 500,
            .width = 400,
        } },
        .gap = 10,
        .position = .center,
        .color = .new(0.5, 0.5, 0.5, 0.8),
        .axis_align = .verical,
        .children = &.{
            .{
                .position = .{ .fixed = .{ .left = 0, .top = 0 } },
                .size = .{ .percent = .{ .heigth = 0.20, .width = 1 } },
                .color = .new(1, 0, 0, 1),
                .axis_align = .horizontal,
                .gap = 20,
                .children = &.{ .{
                    .position = .{ .fixed = .{ .left = 0, .top = 0 } },
                    .size = .{ .percent = .{ .heigth = 1, .width = 0.4 } },
                    .color = .new(1, 1, 0, 1),
                }, .{
                    .name = "button",
                    .text = "hello",
                    .position = .{ .fixed = .{ .left = 0, .top = 0 } },
                    .size = .{ .percent = .{ .heigth = 1, .width = if (ui.isHot("button")) 1 else 0.4 } },
                    .color = if (ui.isHot("button")) .new(1, 1, 1, 1) else .new(1, 1, 0, 1),
                } },
            },
            .{
                .position = .{ .fixed = .{ .left = 0, .top = 0 } },
                .size = .{ .percent = .{ .heigth = 0.20, .width = 1 } },
                .color = .new(1, 1, 0, 1),
            },
        },
    });
    if (ui.isActive("button")) {
        std.log.debug("Pressed button", .{});
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
