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

const Size2D = struct {
    width: f32,
    heigth: f32,
};

const Rect = struct {
    left: f32,
    top: f32,
    width: f32,
    heigth: f32,
};

pub const Layout = struct {
    pub const Position = union(enum) {
        fixed: Position2D,
        center: void,
    };

    position: Position,
    size: Size2D,
    color: nz.color.Rgba(f32) = .grey,
};

const Node = struct {
    layout: Layout,
    parent_id: ?u32,
    rect: Rect,
};

index_buffer: Buffer,
quads: std.ArrayList(Quad) = .empty,
layouts: std.ArrayList(Node) = .empty,
screen_width: f32,
screen_heigth: f32,

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
        .screen_width = @floatFromInt(width),
        .screen_heigth = @floatFromInt(heigth),
    };
}

pub fn deinit(self: *@This(), gpa: std.mem.Allocator, vma: Vma) void {
    self.index_buffer.deinit(vma);
    self.quads.deinit(gpa);
    self.layouts.deinit(gpa);
}

pub fn start(self: *@This()) void {
    self.layouts.clearRetainingCapacity();
    self.quads.clearRetainingCapacity();
}

pub fn add(self: *@This(), parent_id: ?u32, layout: Layout) u32 {
    const handle: u32 = @intCast(self.layouts.items.len);
    self.layouts.appendAssumeCapacity(.{
        .layout = layout,
        .parent_id = parent_id,
        .rect = .{ .left = 0, .top = 0, .width = 0, .heigth = 0 },
    });
    return handle;
}

pub fn end(self: *@This()) void {
    self.resolveLayout();
    self.pushQuads();
}

fn resolveLayout(self: *@This()) void {
    for (self.layouts.items) |*node| {
        node.rect.width = node.layout.size.width;
        node.rect.heigth = node.layout.size.heigth;

        const origin: Rect = if (node.parent_id) |parent_id|
            self.layouts.items[parent_id].rect
        else
            .{ .left = 0, .top = 0, .width = self.screen_width, .heigth = self.screen_heigth };

        switch (node.layout.position) {
            .fixed => |position| {
                node.rect.left = origin.left + position.left;
                node.rect.top = origin.top + position.top;
            },
            .center => {
                node.rect.left = origin.left + (origin.width - node.rect.width) / 2;
                node.rect.top = origin.top + (origin.heigth - node.rect.heigth) / 2;
            },
        }
    }
}

fn pushQuads(self: *@This()) void {
    for (self.layouts.items) |node| {
        const rect = node.rect;
        const colors: [4]f32 = node.layout.color.toVec();
        //left_top, right_top, right_bottom, left_bottom
        self.quads.appendAssumeCapacity(.{ .vertices = .{
            .{ .position = .{ rect.left, rect.top }, .color = colors, .uv = .{ 0, 0 } },
            .{ .position = .{ rect.left + rect.width, rect.top }, .color = colors, .uv = .{ 1, 0 } },
            .{ .position = .{ rect.left + rect.width, rect.top + rect.heigth }, .color = colors, .uv = .{ 1, 1 } },
            .{ .position = .{ rect.left, rect.top + rect.heigth }, .color = colors, .uv = .{ 0, 1 } },
        } });
    }
}
