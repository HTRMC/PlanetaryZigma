const builtin = @import("builtin");
const yes = @import("yes");
const tracy = @import("ztracy");

const native = switch (builtin.os.tag) {
    .windows => @import("window/win32.zig"),
    else => @import("window/default.zig"),
};

pub fn centeredPosition(size: yes.Window.Size) ?yes.Window.Position {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();
    return native.centeredPosition(size);
}
