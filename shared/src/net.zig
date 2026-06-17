const std = @import("std");
const Entity = @import("root.zig").Entity;
const tracy = @import("ztracy");

pub const endian: std.builtin.Endian = .little;

pub const CommandQueue = struct {
    commands: std.ArrayList(Command) = .empty,
    mutex: std.Io.Mutex = .init,
    pub fn deinit(self: *@This(), gpa: std.mem.Allocator, io: std.Io) !void {
        const tracy_scope = tracy.zone(@src());
        defer tracy_scope.end();
        try self.mutex.lock(io);
        self.commands.deinit(gpa);
        self.mutex.unlock(io);
    }
};

pub const Command = union(enum) {
    connect: Connect,
    disconnect: void,
    acknowledge: Acknowledge,
    spawn_entity: SpawnEntity,
    despawn_entity: DespawnEntity,
    input: Input,
    update_transform: UpdateTransform,
    update_camera_rotation: UpdateCameraRotation,

    pub const Opcode = std.meta.Tag(Command);
    //
    // pub const Header = packed struct {
    //     opcode: u16,
    // };

    pub const Parsed = struct {
        // header: Header,
        command: Command,
    };

    pub const Connect = struct {
        name_len: u16,
        name: []const u8,
    };

    pub const Acknowledge = struct {
        id: u32,
    };

    pub const SpawnEntity = struct {
        id: u32,
        kind: Entity.Kind,
        data: [4]u8 = @splat(0),
    };

    pub const DespawnEntity = struct {
        id: u32,
    };

    pub const Input = struct {
        forward: bool = false,
        backward: bool = false,
        right: bool = false,
        left: bool = false,
        up: bool = false,
        down: bool = false,
        r: bool = false,
        k: bool = false,
        mouse_button_left: bool = false,
        mouse_button_right: bool = false,
        mouse_wheel: f64 = 0,
        mouse_delta: [2]f64 = .{ 0, 0 },
    };

    pub const UpdateTransform = struct {
        id: u16,
        position: @Vector(3, f16),
        rotation: @Vector(4, f16),
    };
    pub const UpdateCameraRotation = struct {
        id: u32,
        position: @Vector(3, f32),
        rotation: @Vector(4, f32),
    };

    pub fn write(self: *const @This(), writer: *std.Io.Writer) !void {
        const tracy_scope = tracy.zone(@src());
        defer tracy_scope.end();
        switch (self.*) {
            inline else => |payload, tag| {
                try writer.writeInt(u16, @intFromEnum(tag), endian);
                try marshal(writer, payload);
            },
        }
        // switch (std.meta.activeTag(self.*)) {
        //     inline else => |tag| {
        //         const tag_name = @tagName(tag);
        //
        //         try writer.writeInt(u16, @intFromEnum(self.*), endian);
        //         try marshal(writer, @field(self.*, tag_name));
        //     },
        // }
    }

    pub fn parse(reader: *std.Io.Reader) !Parsed {
        const tracy_scope = tracy.zone(@src());
        defer tracy_scope.end();
        const opcode: Opcode = @enumFromInt(try reader.takeInt(u16, endian));
        switch (opcode) {
            inline else => |tag| {
                return .{ .command = try .parseFromOpcode(reader, tag) };
            },
        }
        unreachable;
    }

    fn parseFromOpcode(reader: *std.Io.Reader, comptime opcode: Opcode) !Command {
        const tracy_scope = tracy.zone(@src());
        defer tracy_scope.end();
        const tag_name = @tagName(opcode);
        const T = @FieldType(Command, tag_name);
        const out = try unmarshal(null, reader, T, true);
        return @unionInit(Command, tag_name, out);
    }

    fn marshal(writer: *std.Io.Writer, value: anytype) !void {
        const tracy_scope = tracy.zone(@src());
        defer tracy_scope.end();
        const T: type = @TypeOf(value);
        switch (@typeInfo(T)) {
            .void => return,
            .bool => try writer.writeInt(u8, @intFromBool(value), endian),
            .int => try writer.writeInt(T, value, endian),
            .float => |float| try writer.writeInt(@Int(.signed, float.bits), @bitCast(value), endian),
            .pointer => |pointer| {
                if (pointer.child == u8)
                    try writer.writeAll(value)
                else
                    try writer.writeSliceEndian(pointer.child, value, endian);
            },
            .array => |array| if (array.child == u8)
                try writer.writeAll(&value)
            else for (value) |item| {
                try marshal(writer, item);
            },
            .vector => |vector| inline for (0..vector.len) |i| {
                try marshal(writer, value[i]);
            },
            .@"struct" => |@"struct"| switch (@"struct".layout) {
                .auto => inline for (std.meta.fields(T)) |field| {
                    const field_value = @field(value, field.name);
                    try marshal(writer, field_value);
                },
                .@"extern" => @compileError("preferred to not serialize structs with extern layout"),
                .@"packed" => try writer.writeStruct(value, endian),
            },
            .@"enum" => |@"enum"| try writer.writeInt(@"enum".tag_type, @intFromEnum(value), endian),
            .enum_literal => try writer.writeAll(@tagName(value)),
            else => @compileError("can not serialize type of " ++ @typeName(T) ++ " aka " ++ @tagName(@typeInfo(T))),
        }
    }

    fn unmarshal(opt_allocator: ?std.mem.Allocator, reader: *std.Io.Reader, Out: type, deserialize_slices: bool) !Out {
        const tracy_scope = tracy.zone(@src());
        defer tracy_scope.end();
        return switch (@typeInfo(Out)) {
            .void => return,
            .bool => try reader.takeByte() == 1,
            .int => try reader.takeInt(Out, endian),
            .float => |float| @bitCast(try reader.takeInt(@Int(.signed, float.bits), endian)),
            .@"enum" => try reader.takeEnum(Out, endian),
            .@"struct" => {
                var out: Out = std.mem.zeroes(Out);

                inline for (@typeInfo(Out).@"struct".fields) |field| @field(out, field.name) = switch (@typeInfo(field.type)) {
                    .bool => try reader.takeByte() == 1,
                    .int => try reader.takeInt(field.type, endian),
                    .float => |float| @bitCast(try reader.takeInt(@Int(.signed, float.bits), endian)),
                    .pointer => |ptr| if (deserialize_slices) slice: {
                        const element_len_name = field.name ++ "_len";
                        std.debug.assert(@typeInfo(@FieldType(Out, element_len_name)) == .int);
                        const element_len: usize = @field(out, element_len_name);
                        if (ptr.child == u8) {
                            const slice = try reader.take(element_len);
                            reader.toss((4 - (slice.len % 4)) % 4);
                            break :slice if (opt_allocator) |allocator| try allocator.dupe(u8, slice) else slice;
                        } else {
                            if (opt_allocator) |allocator| {
                                const slice = try allocator.alloc(ptr.child, element_len);

                                for (0..element_len) |i| {
                                    slice[i] = try unmarshal(allocator, reader, ptr.child, endian, true);
                                }
                                break :slice slice;
                            } else {
                                for (0..element_len) |_| {
                                    _ = try unmarshal(null, reader, ptr.child, endian, true);
                                }

                                break :slice &.{};
                            }
                        }
                    } else &.{},
                    .array => |array| if (array.child == u8) (try reader.takeArray(array.len)).* else array: {
                        var val: field.type = std.mem.zeroes(field.type);
                        for (0..array.len) |i| {
                            val[i] = try unmarshal(opt_allocator, reader, array.child, deserialize_slices);
                        }
                        break :array val;
                    },
                    .vector => |vector| vector: {
                        var val: field.type = @splat(0);
                        inline for (0..vector.len) |i| {
                            val[i] = try unmarshal(opt_allocator, reader, vector.child, deserialize_slices);
                        }
                        break :vector val;
                    },
                    .@"enum" => e: {
                        break :e reader.takeEnum(field.type, endian) catch |err| {
                            std.log.err("{s} {s} {s}", .{ @errorName(err), @typeName(Out), field.name });
                            return err;
                        };
                    },
                    .@"struct" => |s| switch (s.layout) {
                        .auto, .@"extern" => try unmarshal(opt_allocator, reader, field.type, deserialize_slices),
                        .@"packed" => try reader.takeStruct(field.type, endian),
                    },
                    else => @compileError("can not read type of " ++ @typeName(field.type) ++ " aka " ++ @tagName(@typeInfo(field.type))),
                };
                return out;
            },
            else => unreachable,
        };
    }
};
