const builtin = @import("builtin");
const yes = @import("yes");

const native = switch (builtin.os.tag) {
    .windows => @import("window/win32.zig"),
    else => @import("window/default.zig"),
};

pub fn centeredPosition(size: yes.Window.Size) ?yes.Window.Position {
    return native.centeredPosition(size);
}
