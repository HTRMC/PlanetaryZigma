const std = @import("std");
const c = @import("vulkan");
const shaderc = @import("shaderc");
const AssetServer = @import("shared").AssetServer;
const Device = @import("device.zig").Logical;
const ext = @import("procs.zig").device.ProcTable;
const tracy = @import("ztracy");
pub const check = @import("utils.zig").check;

var g_compiler: shaderc.shaderc_compiler_t = null;
fn compiler() shaderc.shaderc_compiler_t {
    if (g_compiler == null) g_compiler = shaderc.shaderc_compiler_initialize();
    return g_compiler;
}

handle: c.VkShaderEXT = null,
device: Device,
shader_create_info: c.VkShaderCreateInfoEXT,
shader_name: []const u8,
push_constant_size: u32,

pub const AnimationPushConstant = extern struct {
    model_matrix: [16]f32,
    vertex_buffer_address: c.VkDeviceAddress,
    inverse_bind_matrices_addess: c.VkDeviceAddress,
};
pub const UiPushConstant = extern struct {
    vertex_buffer_address: c.VkDeviceAddress,
    screnn_size: [2]f32,
};

pub fn init(
    gpa: std.mem.Allocator,
    device: Device,
    asset_server: *AssetServer,
    shader_create_info: c.VkShaderCreateInfoEXT,
    shader_name: []const u8,
    push_constant_type: type,
) !*@This() {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();
    const self = try gpa.create(@This());
    self.* = .{
        .device = device,
        .shader_create_info = shader_create_info,
        .shader_name = shader_name,
        .handle = null,
        .push_constant_size = @sizeOf(push_constant_type),
    };
    try asset_server.loadAsset(@This(), self, shader_name, loadShader);
    return self;
}
pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();
    ext.vkDestroyShaderEXT(self.device.handle, self.handle, null);
    // self.* = undefined;
    gpa.destroy(self);
}

fn loadShader(user_data: *anyopaque, gpa: std.mem.Allocator, io: std.Io, file: std.Io.File, file_path: []const u8) !void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();
    _ = file_path;
    const self: *@This() = @ptrCast(@alignCast(user_data));

    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    const content = try reader.interface.allocRemaining(gpa, .unlimited);
    defer gpa.free(content);

    const ranges: c.VkPushConstantRange = .{
        .stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT,
        .offset = 0,
        .size = self.push_constant_size,
    };
    self.shader_create_info.pPushConstantRanges = &ranges;

    const shader_kind: c_uint = switch (self.shader_create_info.stage) {
        c.VK_SHADER_STAGE_VERTEX_BIT => shaderc.shaderc_glsl_vertex_shader,
        c.VK_SHADER_STAGE_FRAGMENT_BIT => shaderc.shaderc_glsl_fragment_shader,
        else => unreachable,
    };
    const result = shaderc.shaderc_compile_into_spv(compiler(), content.ptr, content.len, shader_kind, self.shader_name.ptr, "main", null);
    defer shaderc.shaderc_result_release(result);
    if (shaderc.shaderc_result_get_compilation_status(result) != shaderc.shaderc_compilation_status_success) {
        std.debug.print("shader {s} compile failed: {s}\n", .{ self.shader_name, shaderc.shaderc_result_get_error_message(result) });
        return error.LoadShader;
    }
    const spv = shaderc.shaderc_result_get_bytes(result)[0..shaderc.shaderc_result_get_length(result)];
    try self.createShader(spv);
}

fn createShader(self: *@This(), spv: []const u8) !void {
    std.debug.assert(@intFromPtr(spv.ptr) % 4 == 0);
    self.shader_create_info.codeSize = spv.len;
    self.shader_create_info.pCode = @ptrCast(spv.ptr);
    if (self.handle != null) ext.vkDestroyShaderEXT(self.device.handle, self.handle, null);
    try check(ext.vkCreateShadersEXT(self.device.handle, 1, &self.shader_create_info, null, &self.handle));
}
