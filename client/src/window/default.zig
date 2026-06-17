const yes = @import("yes");
const tracy = @import("ztracy");

pub fn centeredPosition(size: yes.Window.Size) ?yes.Window.Position {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();
    _ = size;
    return null;
}
