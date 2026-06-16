const std = @import("std");
const shared = @import("shared");
const system = @import("../system.zig");
const tracy = @import("ztracy");
const nz = shared.numz;

pub const zphy = @import("zphy");

gpa: std.mem.Allocator,
io: std.Io,
global_state_reload: zphy.GlobalState,
physics_system: *zphy.PhysicsSystem,
broad_phase_layer_interface: *BroadPhaseLayerInterface,
object_layer_pair_filter: *ObjectLayerPairFilter,
object_vs_broad_phase_layer_filter: *ObjectVsBroadPhaseLayerFilter,
contact_listener: *ContactListener,

pub const Collider = struct {
    const Primitive = union(enum) {
        box: struct {
            size: f32,
        },
        capsule: struct {
            size: f32,
        },
        sphere: struct {
            size: f32,
        },
    };

    const Mesh = struct {
        // render_handle: usize,
        indices: []u32,
        vertices: [][4]f32,
    };
    shape: union(enum) { primitive: Primitive, mesh: Mesh },
    body_id: ?zphy.BodyId = null,
    motion_type: zphy.MotionType,
    // max_angular_velocity: f32 = 1,
};

const object_layers = struct {
    const non_moving: zphy.ObjectLayer = 0;
    const moving: zphy.ObjectLayer = 1;
    const len: u32 = 2;
};

const broad_phase_layers = struct {
    const non_moving: zphy.BroadPhaseLayer = 0;
    const moving: zphy.BroadPhaseLayer = 1;
    const len: u32 = 2;
};

const BroadPhaseLayerInterface = extern struct {
    broad_phase_layer_interface: zphy.BroadPhaseLayerInterface = .init(@This()),
    object_to_broad_phase: [object_layers.len]zphy.BroadPhaseLayer = undefined,

    fn init() BroadPhaseLayerInterface {
        const tracy_scope = tracy.zone(@src());
        defer tracy_scope.end();
        var object_to_broad_phase: [object_layers.len]zphy.BroadPhaseLayer = undefined;
        object_to_broad_phase[object_layers.non_moving] = broad_phase_layers.non_moving;
        object_to_broad_phase[object_layers.moving] = broad_phase_layers.moving;
        return .{ .object_to_broad_phase = object_to_broad_phase };
    }

    fn selfPtr(broad_phase_layer_interface: *zphy.BroadPhaseLayerInterface) *BroadPhaseLayerInterface {
        const tracy_scope = tracy.zone(@src());
        defer tracy_scope.end();
        return @alignCast(@fieldParentPtr("broad_phase_layer_interface", broad_phase_layer_interface));
    }

    fn selfPtrConst(broad_phase_layer_interface: *const zphy.BroadPhaseLayerInterface) *const BroadPhaseLayerInterface {
        const tracy_scope = tracy.zone(@src());
        defer tracy_scope.end();
        return @alignCast(@fieldParentPtr("broad_phase_layer_interface", broad_phase_layer_interface));
    }

    pub fn getNumBroadPhaseLayers(_: *const zphy.BroadPhaseLayerInterface) callconv(.c) u32 {
        const tracy_scope = tracy.zone(@src());
        defer tracy_scope.end();
        return broad_phase_layers.len;
    }

    pub fn getBroadPhaseLayer(
        broad_phase_layer_interface: *const zphy.BroadPhaseLayerInterface,
        layer: zphy.ObjectLayer,
    ) callconv(.c) zphy.BroadPhaseLayer {
        const tracy_scope = tracy.zone(@src());
        defer tracy_scope.end();
        return selfPtrConst(broad_phase_layer_interface).object_to_broad_phase[layer];
    }
};
const ObjectVsBroadPhaseLayerFilter = extern struct {
    object_vs_broad_phase_layer_filter: zphy.ObjectVsBroadPhaseLayerFilter = .init(@This()),

    pub fn shouldCollide(
        _: *const zphy.ObjectVsBroadPhaseLayerFilter,
        layer1: zphy.ObjectLayer,
        layer2: zphy.BroadPhaseLayer,
    ) callconv(.c) bool {
        const tracy_scope = tracy.zone(@src());
        defer tracy_scope.end();
        return switch (layer1) {
            object_layers.non_moving => layer2 == broad_phase_layers.moving,
            object_layers.moving => true,
            else => unreachable,
        };
    }
};
const ObjectLayerPairFilter = extern struct {
    object_layer_pair_filter: zphy.ObjectLayerPairFilter = .init(@This()),

    pub fn shouldCollide(
        _: *const zphy.ObjectLayerPairFilter,
        object1: zphy.ObjectLayer,
        object2: zphy.ObjectLayer,
    ) callconv(.c) bool {
        const tracy_scope = tracy.zone(@src());
        defer tracy_scope.end();
        return switch (object1) {
            object_layers.non_moving => object2 == object_layers.moving,
            object_layers.moving => true,
            else => unreachable,
        };
    }
};

const ContactListener = extern struct {
    contact_listener: zphy.ContactListener = .init(@This()),

    fn selfPtr(contact_listener: *zphy.ContactListener) *ContactListener {
        const tracy_scope = tracy.zone(@src());
        defer tracy_scope.end();
        return @alignCast(@fieldParentPtr("contact_listener", contact_listener));
    }

    fn selfPtrConst(contact_listener: *const zphy.ContactListener) *const ContactListener {
        const tracy_scope = tracy.zone(@src());
        defer tracy_scope.end();
        return @alignCast(@fieldParentPtr("contact_listener", contact_listener));
    }

    pub fn onContactValidate(
        contact_listener: *zphy.ContactListener,
        body1: *const zphy.Body,
        body2: *const zphy.Body,
        base_offset: *const [3]zphy.Real,
        collision_result: *const zphy.CollideShapeResult,
    ) callconv(.c) zphy.ValidateResult {
        const tracy_scope = tracy.zone(@src());
        defer tracy_scope.end();
        _ = contact_listener;
        _ = body1;
        _ = body2;
        _ = base_offset;
        _ = collision_result;
        return .accept_all_contacts;
    }

    pub fn onContactAdded(
        contact_listener: *zphy.ContactListener,
        body1: *const zphy.Body,
        body2: *const zphy.Body,
        _: *const zphy.ContactManifold,
        _: *zphy.ContactSettings,
    ) callconv(.c) void {
        const tracy_scope = tracy.zone(@src());
        defer tracy_scope.end();
        _ = contact_listener;
        _ = body1;
        _ = body2;
    }

    pub fn onContactPersisted(
        contact_listener: *zphy.ContactListener,
        body1: *const zphy.Body,
        body2: *const zphy.Body,
        _: *const zphy.ContactManifold,
        _: *zphy.ContactSettings,
    ) callconv(.c) void {
        const tracy_scope = tracy.zone(@src());
        defer tracy_scope.end();
        _ = contact_listener;
        _ = body1;
        _ = body2;
    }

    pub fn onContactRemoved(
        contact_listener: *zphy.ContactListener,
        sub_shape_id_pair: *const zphy.SubShapeIdPair,
    ) callconv(.c) void {
        const tracy_scope = tracy.zone(@src());
        defer tracy_scope.end();
        _ = contact_listener;
        _ = sub_shape_id_pair;
    }
};

pub fn init(self: *@This(), gpa: std.mem.Allocator, io: std.Io) !void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();
    try zphy.init(gpa, io, .{});
    const broad_phase_layer_interface = try gpa.create(BroadPhaseLayerInterface);
    broad_phase_layer_interface.* = BroadPhaseLayerInterface.init();
    const object_layer_pair_filter = try gpa.create(ObjectLayerPairFilter);
    object_layer_pair_filter.* = .{};
    const object_vs_broad_phase_layer_filter = try gpa.create(ObjectVsBroadPhaseLayerFilter);
    object_vs_broad_phase_layer_filter.* = .{};
    const contact_listener = try gpa.create(ContactListener);
    contact_listener.* = .{};

    // Create physics system
    const physics_system = try zphy.PhysicsSystem.create(
        @as(*const zphy.BroadPhaseLayerInterface, @ptrCast(@alignCast(broad_phase_layer_interface))),
        @as(*const zphy.ObjectVsBroadPhaseLayerFilter, @ptrCast(@alignCast(object_vs_broad_phase_layer_filter))),
        @as(*const zphy.ObjectLayerPairFilter, @ptrCast(@alignCast(object_layer_pair_filter))),
        .{
            .max_bodies = 4096,
            .num_body_mutexes = 0,
            .max_body_pairs = 16384,
            .max_contact_constraints = 8192,
        },
    );

    physics_system.setGravity(.{ 0, 0, 0 });

    physics_system.optimizeBroadPhase();

    const planet: shared.Planet(.logical) = try .init(gpa, 10);

    const mesh_shape_setting = try zphy.MeshShapeSettings.create(
        planet.vertices.ptr,
        @intCast(planet.vertices.len),
        @sizeOf([4]f32),
        planet.indices,
    );
    zphy.MeshShapeSettings.sanitize(mesh_shape_setting);
    defer mesh_shape_setting.asShapeSettings().release();
    const custom_shape = try mesh_shape_setting.asShapeSettings().createShape();

    const body_interface = physics_system.getBodyInterfaceMut();
    const body_id = try body_interface.createAndAddBody(.{
        .position = .{ 0, 0, 0, 1 },
        .rotation = .{ 0, 0, 0, 1 },
        .shape = custom_shape,
        .motion_type = .static,
        .object_layer = object_layers.moving,
        // .user_data = @intFromEnum(entry),
        .angular_velocity = .{ 0.0, 0.0, 0.0, 0 },
        // .max_angular_velocity = collider.max_angular_velocity,
        //.allow_sleeping = false,
    }, .activate);
    _ = body_id;

    self.* = .{
        .global_state_reload = undefined,
        .gpa = gpa,
        .io = io,
        .contact_listener = contact_listener,
        .physics_system = physics_system,
        .broad_phase_layer_interface = broad_phase_layer_interface,
        .object_layer_pair_filter = object_layer_pair_filter,
        .object_vs_broad_phase_layer_filter = object_vs_broad_phase_layer_filter,
    };
}

//NOTE: Jolt leaks memory ;_;
pub fn deinit(self: *@This()) void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();
    std.log.err(
        \\
        \\╔════════════════════════════════════╗
        \\║ Jolt leaks 4 memory addresses!     ║
        \\╚════════════════════════════════════╝
    , .{});
    self.gpa.destroy(self.contact_listener);
    self.gpa.destroy(self.broad_phase_layer_interface);
    self.gpa.destroy(self.object_layer_pair_filter);
    self.gpa.destroy(self.object_vs_broad_phase_layer_filter);
    zphy.PhysicsSystem.destroy(self.physics_system);
    zphy.deinit();
}

pub fn reload(self: *@This(), pre_reload: bool, world: *system.World) !void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();
    if (pre_reload) {
        // Serialize body states before destroying
        // TODO: Implement body serialization when you have active bodies
        std.log.debug("before", .{});

        // Destroy physics system to stop worker threads before unload
        zphy.PhysicsSystem.destroy(self.physics_system);

        std.log.debug("After", .{});
        self.physics_system = undefined;
        self.global_state_reload = zphy.preReload();
    } else {
        zphy.postReload(self.gpa, self.io, self.global_state_reload);

        // Refresh vtable pointers FIRST - before creating physics system
        self.broad_phase_layer_interface.broad_phase_layer_interface = zphy.BroadPhaseLayerInterface.init(BroadPhaseLayerInterface);
        self.object_vs_broad_phase_layer_filter.object_vs_broad_phase_layer_filter = zphy.ObjectVsBroadPhaseLayerFilter.init(ObjectVsBroadPhaseLayerFilter);
        self.object_layer_pair_filter.object_layer_pair_filter = zphy.ObjectLayerPairFilter.init(ObjectLayerPairFilter);
        self.contact_listener.contact_listener = zphy.ContactListener.init(ContactListener);

        // Recreate physics system with fresh vtable pointers
        self.physics_system = zphy.PhysicsSystem.create(
            @as(*const zphy.BroadPhaseLayerInterface, @ptrCast(@alignCast(self.broad_phase_layer_interface))),
            @as(*const zphy.ObjectVsBroadPhaseLayerFilter, @ptrCast(@alignCast(self.object_vs_broad_phase_layer_filter))),
            @as(*const zphy.ObjectLayerPairFilter, @ptrCast(@alignCast(self.object_layer_pair_filter))),
            .{
                .max_bodies = 4096,
                .num_body_mutexes = 0,
                .max_body_pairs = 16384,
                .max_contact_constraints = 8192,
            },
        ) catch unreachable;
        self.physics_system.setGravity(.{ 0, 0, 0 });
        for (world.entities.values()) |*entity| {
            if (!entity.flags.collider or !entity.flags.transform) continue;
            entity.collider.body_id = null;
            try self.createBody(entity);
        }
    }
}

pub fn update(self: *@This(), info: *const system.Info) !void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();
    const body_interface = self.physics_system.getBodyInterfaceMut();

    // 1. Apply custom gravity per dynamic entity.
    for (info.world.entities.values()) |*entity| {
        if (!entity.flags.collider or !entity.flags.transform) continue;
        const body_id = entity.collider.body_id orelse continue;
        if (entity.collider.motion_type != .dynamic) continue;

        const up_len = nz.vec.length(entity.transform.position);
        if (up_len < 0.0001) continue;
        const up = nz.vec.scale(entity.transform.position, 1.0 / up_len);
        body_interface.addForce(body_id, nz.vec.scale(-up, 1000000));
    }

    self.physics_system.update(info.delta_time, .{}) catch unreachable;

    for (info.world.entities.values()) |*entity| {
        if (!entity.flags.collider or !entity.flags.transform) continue;
        const body_id = entity.collider.body_id orelse continue;

        const pos = body_interface.getPosition(body_id);
        entity.transform.position = .{
            @floatCast(pos[0]), @floatCast(pos[1]), @floatCast(pos[2]),
        };
        entity.transform.rotation = .fromVec(body_interface.getRotation(body_id));
    }

    self.alignToPlanet(info); //TODO: before physics? or do indivual per entity movement?
}

fn alignToPlanet(self: *@This(), info: *const system.Info) void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();
    const body_interface = self.physics_system.getBodyInterfaceMut();

    for (info.world.entities.values()) |*entity| {
        if (!entity.flags.align_to_planet or !entity.flags.transform or !entity.flags.collider) continue;
        const transform = &entity.transform;

        const desired_up: nz.Vec3(f32) = nz.vec.normalize(transform.position);
        const current_up: nz.Vec3(f32) = transform.up();

        const d = std.math.clamp(nz.vec.dot(current_up, desired_up), -1.0, 1.0);
        if (d >= 0.9999) continue;

        const axis: nz.Vec3(f32) = if (d > -0.9999)
            nz.vec.normalize(nz.vec.cross(current_up, desired_up))
        else
            nz.vec.normalize(nz.vec.cross(current_up, transform.forward()));
        const angle = std.math.acos(d);
        const align_quat: nz.quat.Hamiltonian(f32) = .angleAxis(angle, axis);
        transform.rotation = align_quat.mul(transform.rotation).normalize();

        if (entity.collider.body_id) |id| {
            body_interface.setRotation(id, transform.rotation.toVec(), .activate);
        }
    }
}

pub fn createBody(self: *@This(), entity: *system.Entity) !void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();
    const collider = &entity.collider;
    const transform = entity.transform;
    const matrix = transform.toMat4x4();
    const body_interface = self.physics_system.getBodyInterfaceMut();

    const shape = switch (collider.shape) {
        .primitive => |primitive| switch (primitive) {
            .box => |box| shape: {
                const settings = try zphy.BoxShapeSettings.create(.{ box.size, box.size, box.size });
                defer settings.asShapeSettings().release();
                break :shape try settings.asShapeSettings().createShape();
            },
            .sphere => shape: {
                const settings = try zphy.SphereShapeSettings.create(1);
                defer settings.asShapeSettings().release();
                break :shape try settings.asShapeSettings().createShape();
            },
            .capsule => shape: {
                const settings = try zphy.CapsuleShapeSettings.create(1, 1);
                defer settings.asShapeSettings().release();
                break :shape try settings.asShapeSettings().createShape();
            },
        },
        .mesh => |mesh_shape| shape: {
            const settings = try zphy.MeshShapeSettings.create(
                mesh_shape.vertices.ptr,
                @intCast(mesh_shape.vertices.len),
                @sizeOf([4]f32),
                mesh_shape.indices,
            );
            zphy.MeshShapeSettings.sanitize(settings);
            defer settings.asShapeSettings().release();
            break :shape try settings.asShapeSettings().createShape();
        },
    };
    defer shape.release();

    const translation_only: zphy.AllowedDOFs = @enumFromInt(
        @intFromEnum(zphy.AllowedDOFs.translation_x) |
            @intFromEnum(zphy.AllowedDOFs.translation_y) |
            @intFromEnum(zphy.AllowedDOFs.translation_z),
    );
    const body_id = try body_interface.createAndAddBody(.{
        .position = matrix.vec4Position(),
        .rotation = transform.rotation.toVec(),
        .shape = shape,
        .motion_type = collider.motion_type,
        .object_layer = object_layers.moving,
        .user_data = entity.id,
        .angular_velocity = .{ 0.0, 0.0, 0.0, 0 },
        .allowed_DOFs = translation_only,
        .override_mass_properties = .calc_inertia,
        .mass_properties_override = .{ .mass = 10000 },
        .max_linear_velocity = 10000,
        .allow_sleeping = false,
    }, .activate);
    collider.body_id = body_id;
}

pub fn destroyBody(self: *@This(), body_id: zphy.BodyId) void {
    const tracy_scope = tracy.zone(@src());
    defer tracy_scope.end();
    const body_interface = self.physics_system.getBodyInterfaceMut();
    body_interface.removeAndDestroyBody(body_id);
}
