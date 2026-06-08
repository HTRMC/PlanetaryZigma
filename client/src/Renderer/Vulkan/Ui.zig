const std = @import("std");
const c = @import("vulkan");
const nz = @import("shared").numz;
const Buffer = @import("Buffer.zig");
const Vma = @import("Vma.zig");
const Device = @import("device.zig").Logical;

pub const max_ui_quads: usize = 1024;

pub const Vertex = extern struct {
    position: [2]f32,
    uv: [2]f32,
    color: [4]f32,
};

pub const Quad = struct {
    vertices: [4]Vertex,
};

const Position2D = struct {
    left: f32,
    top: f32,
};

pub const Layout = struct {
    const Position = union(enum) {
        fixed: Position2D,
        center: void,
    };
    const Size = union(enum) {
        fixed: struct {
            width: f32,
            heigth: f32,
        },
        fit: void,
    };

    children: std.ArrayList(*Layout) = .empty,
    position: Position,
    size: Size,
    color: nz.color.Rgba(f32) = .grey,
};

index_buffer: Buffer,
quads: std.ArrayList(Quad) = .empty,
layouts: std.ArrayList(Layout) = .empty,
root_layouts: std.ArrayList(*Layout) = .empty,
width: f32,
heigth: f32,

pub fn init(gpa: std.mem.Allocator, vma: Vma, device: Device, width: u32, heigth: u32) !@This() {
    const ui_index_buffer: Buffer = try .init(
        device,
        vma,
        u32,
        max_ui_quads * 6,
        c.VK_BUFFER_USAGE_INDEX_BUFFER_BIT,
        .{
            .usage = c.VMA_MEMORY_USAGE_AUTO,
            .flags = c.VMA_ALLOCATION_CREATE_MAPPED_BIT | c.VMA_ALLOCATION_CREATE_HOST_ACCESS_SEQUENTIAL_WRITE_BIT,
        },
    );
    var data: [*]u32 = @ptrCast(@alignCast(ui_index_buffer.info.pMappedData));
    for (0..max_ui_quads) |i| {
        const base: u32 = @as(u32, @intCast(i)) * 4;
        data[i * 6 ..][0..6].* = .{ base, base + 1, base + 2, base + 2, base + 3, base };
    }
    return .{
        .index_buffer = ui_index_buffer,
        .quads = try .initCapacity(gpa, max_ui_quads),
        .layouts = try .initCapacity(gpa, max_ui_quads),
        .root_layouts = try .initCapacity(gpa, max_ui_quads),
        .width = @floatFromInt(width),
        .heigth = @floatFromInt(heigth),
    };
}

pub fn deinit(self: *@This(), gpa: std.mem.Allocator, vma: Vma) void {
    for (self.layouts.items) |*layout| {
        layout.children.deinit(gpa);
    }
    self.index_buffer.deinit(vma);
    self.quads.deinit(gpa);
    self.root_layouts.deinit(gpa);
    self.layouts.deinit(gpa);
}

pub fn start(self: *@This(), gpa: std.mem.Allocator) void {
    for (self.layouts.items) |*layout| {
        layout.children.deinit(gpa);
    }
    self.layouts.clearRetainingCapacity();
    self.quads.clearRetainingCapacity();
    self.root_layouts.clearRetainingCapacity();
}

pub fn addRootLayout(self: *@This(), layout: Layout) *Layout {
    //top, left, right, bottom,
    const positions: [2]f32 = switch (layout.position) {
        .center => blk: {
            const screen_half_width = self.width / 2;
            const screen_half_height = self.heigth / 2;
            break :blk .{
                screen_half_height,
                screen_half_width,
            };
        },
        .fixed => |position| .{
            position.top, position.left,
        },
    };

    self.layouts.appendAssumeCapacity(layout);
    var last_root = &self.layouts.items[self.layouts.items.len - 1];
    last_root.position = .{ .fixed = .{ .left = positions[1], .top = positions[0] } };
    self.root_layouts.appendAssumeCapacity(last_root);
    return last_root;
}

pub fn addChildLayout(self: *@This(), gpa: std.mem.Allocator, parent: *Layout, child: Layout) !*Layout {
    //top, left, right, bottom,
    const positions: [4]f32 = switch (child.position) {
        .center => blk: {
            const layout_half_height = child.size.fixed.heigth / 2;
            const layout_half_width = child.size.fixed.width / 2;
            break :blk .{
                parent.position.fixed.top - layout_half_height,
                parent.position.fixed.left - layout_half_width,
                parent.position.fixed.left + layout_half_width,
                parent.position.fixed.top + layout_half_height,
            };
        },
        .fixed => |position| .{
            position.top + parent.position.fixed.top,
            position.left + parent.position.fixed.left,
            position.left + child.size.fixed.width + parent.position.fixed.left,
            position.top + child.size.fixed.heigth + parent.position.fixed.top,
        },
    };
    self.layouts.appendAssumeCapacity(child);
    var new_layout = &self.layouts.items[self.layouts.items.len - 1];
    new_layout.position = .{ .fixed = .{ .left = positions[1], .top = positions[0] } };
    try parent.children.append(gpa, new_layout);
    return new_layout;
}

pub fn end(self: *@This()) void {
    for (self.root_layouts.items) |layout| {
        self.appendQuad(layout);
    }
    std.mem.reverse(Quad, self.quads.items);
}

fn appendQuad(self: *@This(), layout: *Layout) void {
    for (layout.children.items) |child| {
        self.appendQuad(child);
    }
    const position = layout.position.fixed;
    const positions: [4]f32 = .{
        position.top,
        position.left,
        position.left + layout.size.fixed.width,
        position.top + layout.size.fixed.heigth,
    };

    const colors: [4]f32 = layout.color.toVec();
    //left_top, right_top, right_bottom, left_bottom
    self.quads.appendAssumeCapacity(.{ .vertices = .{
        .{ .position = .{ positions[1], positions[0] }, .color = colors, .uv = .{ 0, 0 } },
        .{ .position = .{ positions[2], positions[0] }, .color = colors, .uv = .{ 1, 0 } },
        .{ .position = .{ positions[2], positions[3] }, .color = colors, .uv = .{ 1, 1 } },
        .{ .position = .{ positions[1], positions[3] }, .color = colors, .uv = .{ 0, 1 } },
    } });
}
