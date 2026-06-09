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

const MouseState = struct {
    position: Position2D = .{ .left = 0, .top = 0 },
    left_click: bool = false,
    right_click: bool = false,
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
    pub const AxisAlign = enum(u8) { horizontal, verical };
    pub const Position = union(enum) {
        fixed: Position2D,
        center: void,
    };
    pub const Size = union(enum) {
        fixed: Size2D,
        percent: Size2D,
    };

    position: Position,
    size: Size,
    color: nz.color.Rgba(f32) = .grey,
    axis_align: AxisAlign = .horizontal,
};

const Node = struct {
    id: u32,
    layout: Layout,
    name: ?[]const u8,
    parent_id: ?u32,
    rect: Rect,
    offset: f32,
};

index_buffer: Buffer,
quads: std.ArrayList(Quad) = .empty,
nodes: std.ArrayList(Node) = .empty,
names: std.StringArrayHashMapUnmanaged(u32) = .empty,
mouse_state: MouseState = .{},
screen_width: f32,
screen_heigth: f32,
hot_item: ?[]const u8 = null,
active_item: ?[]const u8 = null,
fire_item: ?[]const u8 = null,
left_click_prev: bool = false,
pressed: bool = false,
released: bool = false,

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
    var names: std.StringArrayHashMapUnmanaged(u32) = .empty;
    try names.ensureTotalCapacity(gpa, max_ui_quads);
    return .{
        .index_buffer = ui_index_buffer,
        .quads = try .initCapacity(gpa, max_ui_quads),
        .nodes = try .initCapacity(gpa, max_ui_quads),
        .names = names,
        .screen_width = @floatFromInt(width),
        .screen_heigth = @floatFromInt(heigth),
    };
}

pub fn deinit(self: *@This(), gpa: std.mem.Allocator, vma: Vma) void {
    self.index_buffer.deinit(vma);
    self.quads.deinit(gpa);
    self.nodes.deinit(gpa);
    self.names.deinit(gpa);
}

pub fn start(self: *@This(), mouse_state: MouseState) void {
    self.hotUpdate();
    // self.activeUpdate();
    self.left_click_prev = mouse_state.left_click;
    self.nodes.clearRetainingCapacity();
    self.quads.clearRetainingCapacity();
    self.names.clearRetainingCapacity();
    self.mouse_state = mouse_state;
}

pub fn add(self: *@This(), parent_id: ?u32, name: ?[]const u8, layout: Layout) u32 {
    const handle: u32 = @intCast(self.nodes.items.len);
    self.nodes.appendAssumeCapacity(.{
        .id = @intCast(self.nodes.items.len),
        .name = name,
        .layout = layout,
        .parent_id = parent_id,
        .rect = .{ .left = 0, .top = 0, .width = 0, .heigth = 0 },
        .offset = 0,
    });
    if (name) |add_name| self.names.putAssumeCapacity(add_name, handle);
    return handle;
}

pub fn end(self: *@This()) void {
    self.resolveLayout();
    self.pushQuads();
}

//TODO: add FIT,
//add percent position,
//add indivual component properties (width: fixed, heigth: center).
fn resolveLayout(self: *@This()) void {
    for (self.nodes.items) |*node| {
        const parent_node = if (node.parent_id) |parent_id| &self.nodes.items[parent_id] else null;
        const origin: Rect = if (parent_node) |parent| parent.rect else .{
            .left = 0,
            .top = 0,
            .width = self.screen_width,
            .heigth = self.screen_heigth,
        };

        switch (node.layout.size) {
            .fixed => |size| {
                node.rect.width = size.width;
                node.rect.heigth = size.heigth;
            },
            .percent => |percent| {
                node.rect.width = percent.width * origin.width;
                node.rect.heigth = percent.heigth * origin.heigth;
            },
        }

        var offset_top: f32 = 0;
        var offset_left: f32 = 0;
        if (parent_node) |parent| {
            if (parent.layout.axis_align == .horizontal) offset_left = parent.offset else offset_top = parent.offset;
        }
        switch (node.layout.position) {
            .fixed => |position| {
                node.rect.left = origin.left + position.left + offset_left;
                node.rect.top = origin.top + position.top + offset_top;
            },
            .center => {
                node.rect.left = origin.left + (origin.width - node.rect.width - offset_left) / 2;
                node.rect.top = origin.top + (origin.heigth - node.rect.heigth - offset_top) / 2;
            },
        }

        if (parent_node) |parent| {
            parent.offset += switch (parent.layout.axis_align) {
                .horizontal => node.rect.width,
                .verical => node.rect.heigth,
            };
        }
    }
}

fn pushQuads(self: *@This()) void {
    for (self.nodes.items) |node| {
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

// pub fn clicked(self: *@This(), id: u32) ?*Layout {
//     if (id >= self.nodes.items.len) return null;
//     const node = self.nodes.items[id];
// }

pub fn isHot(self: *@This(), name: []const u8) bool {
    return eqlName(name, self.hot_item);
}

pub fn isActive(self: *@This(), name: []const u8) bool {
    return (eqlName(name, self.hot_item) and self.mouse_state.left_click);
}

fn hotUpdate(self: *@This()) void {
    self.hot_item = null;
    var i = self.nodes.items.len;
    while (i > 0) {
        i -= 1;
        const node = self.nodes.items[i];
        const name = node.name orelse continue;
        if (!(self.mouse_state.position.left < node.rect.left or
            self.mouse_state.position.top < node.rect.top or
            self.mouse_state.position.left >= node.rect.left + node.rect.width or
            self.mouse_state.position.top >= node.rect.top + node.rect.heigth))
        {
            self.hot_item = name;
            break;
        }
    }
}

// fn activeUpdate(self: *@This()) void {
//     if (self.hot_item)
//     if (self.left_click_prev) return;
// }

fn eqlName(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null)
        return false;
    return std.mem.eql(u8, a.?, b.?);
}
