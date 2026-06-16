const yes = @import("yes");

const SM_CXSCREEN: c_int = 0;
const SM_CYSCREEN: c_int = 1;
extern "user32" fn GetSystemMetrics(index: c_int) callconv(.winapi) c_int;

pub fn centeredPosition(size: yes.Window.Size) ?yes.Window.Position {
    const screen_w = GetSystemMetrics(SM_CXSCREEN);
    const screen_h = GetSystemMetrics(SM_CYSCREEN);

    return .{
        .x = @max(0, @divTrunc(screen_w - @as(c_int, @intCast(size.width)), 2)),
        .y = @max(0, @divTrunc(screen_h - @as(c_int, @intCast(size.height)), 2)),
    };
}
