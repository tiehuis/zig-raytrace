const std = @import("std");

const multithread = true;

fn vec3(x: f32, y: f32, z: f32) Vec3f {
    return Vec3f{ .x = x, .y = y, .z = z };
}

const Vec3f = Vec3(f32);

fn Vec3(comptime T: type) type {
    return struct {
        const Self = @This();

        x: T,
        y: T,
        z: T,

        fn mul(u: Self, v: Self) T {
            return u.x * v.x + u.y * v.y + u.z * v.z;
        }

        fn mulScalar(u: Self, k: T) Self {
            return vec3(u.x * k, u.y * k, u.z * k);
        }

        fn add(u: Self, v: Self) Self {
            return vec3(u.x + v.x, u.y + v.y, u.z + v.z);
        }

        fn sub(u: Self, v: Self) Self {
            return vec3(u.x - v.x, u.y - v.y, u.z - v.z);
        }

        fn negate(u: Self) Self {
            return vec3(-u.x, -u.y, -u.z);
        }

        fn norm(u: Self) T {
            return std.math.sqrt(u.x * u.x + u.y * u.y + u.z * u.z);
        }

        fn normalize(u: Self) Self {
            return u.mulScalar(1 / u.norm());
        }

        fn cross(u: Vec3f, v: Vec3f) Vec3f {
            return vec3(
                u.y * v.z - u.z * v.y,
                u.z * v.x - u.x * v.z,
                u.x * v.y - u.y * v.x,
            );
        }
    };
}

const Light = struct {
    position: Vec3f,
    intensity: f32,
};

const Material = struct {
    refractive_index: f32,
    albedo: [4]f32,
    diffuse_color: Vec3f,
    specular_exponent: f32,

    pub fn default() Material {
        return Material{
            .refractive_index = 1,
            .albedo = []f32{ 1, 0, 0, 0 },
            .diffuse_color = vec3(0, 0, 0),
            .specular_exponent = 0,
        };
    }
};

const Sphere = struct {
    center: Vec3f,
    radius: f32,
    material: Material,

    fn rayIntersect(self: Sphere, origin: Vec3f, direction: Vec3f, t0: *f32) bool {
        const l = self.center.sub(origin);
        const tca = l.mul(direction);
        const d2 = l.mul(l) - tca * tca;

        if (d2 > self.radius * self.radius) {
            return false;
        }

        const thc = std.math.sqrt(self.radius * self.radius - d2);
        t0.* = tca - thc;
        const t1 = tca + thc;
        if (t0.* < 0) t0.* = t1;
        return t0.* >= 0;
    }
};

fn reflect(i: Vec3f, normal: Vec3f) Vec3f {
    return i.sub(normal.mulScalar(2).mulScalar(i.mul(normal)));
}

fn refract(i: Vec3f, normal: Vec3f, refractive_index: f32) Vec3f {
    var cosi = -std.math.max(-1, std.math.min(1, i.mul(normal)));
    var etai: f32 = 1;
    var etat = refractive_index;

    var n = normal;
    if (cosi < 0) {
        cosi = -cosi;
        std.mem.swap(f32, &etai, &etat);
        n = normal.negate();
    }

    const eta = etai / etat;
    const k = 1 - eta * eta * (1 - cosi * cosi);
    return if (k < 0) vec3(0, 0, 0) else i.mulScalar(eta).add(n.mulScalar(eta * cosi - std.math.sqrt(k)));
}

fn sceneIntersect(origin: Vec3f, direction: Vec3f, spheres: []const Sphere, hit: *Vec3f, normal: *Vec3f, material: *Material) bool {
    var spheres_dist: f32 = std.math.f32_max;
    for (spheres) |s| {
        var dist_i: f32 = undefined;
        if (s.rayIntersect(origin, direction, &dist_i) and dist_i < spheres_dist) {
            spheres_dist = dist_i;
            hit.* = origin.add(direction.mulScalar(dist_i));
            normal.* = hit.sub(s.center).normalize();
            material.* = s.material;
        }
    }

    // Floor plane
    var checkerboard_dist: f32 = std.math.f32_max;
    if (std.math.fabs(direction.y) > 1e-3) {
        const d = -(origin.y + 4) / direction.y;
        const pt = origin.add(direction.mulScalar(d));
        if (d > 0 and std.math.fabs(pt.x) < 10 and pt.z < -10 and pt.z > -30 and d < spheres_dist) {
            checkerboard_dist = d;
            hit.* = pt;
            normal.* = vec3(0, 1, 0);

            const diffuse = @floatToInt(i32, 0.5 * hit.x + 1000) + @floatToInt(i32, 0.5 * hit.z);
            const diffuse_color = if (@mod(diffuse, 2) == 1) vec3(1, 1, 1) else vec3(1, 0.7, 0.3);
            material.diffuse_color = diffuse_color.mulScalar(0.3);
        }
    }

    return std.math.min(spheres_dist, checkerboard_dist) < 1000;
}

fn castRay(origin: Vec3f, direction: Vec3f, spheres: []const Sphere, lights: []const Light, depth: i32) Vec3f {
    var point: Vec3f = undefined;
    var normal: Vec3f = undefined;
    var material = Material.default();

    if (depth > 4 or !sceneIntersect(origin, direction, spheres, &point, &normal, &material)) {
        return vec3(0.2, 0.7, 0.8); // Background color
    }

    const reflect_dir = reflect(direction, normal).normalize();
    const refract_dir = refract(direction, normal, material.refractive_index).normalize();

    const nn = normal.mulScalar(1e-3);
    const reflect_origin = if (reflect_dir.mul(normal) < 0) point.sub(nn) else point.add(nn);
    const refract_origin = if (refract_dir.mul(normal) < 0) point.sub(nn) else point.add(nn);

    const reflect_color = castRay(reflect_origin, reflect_dir, spheres, lights, depth + 1);
    const refract_color = castRay(refract_origin, refract_dir, spheres, lights, depth + 1);

    var diffuse_light_intensity: f32 = 0;
    var specular_light_intensity: f32 = 0;

    for (lights) |l| {
        const light_dir = l.position.sub(point).normalize();
        const light_distance = l.position.sub(point).norm();

        const shadow_origin = if (light_dir.mul(normal) < 0) point.sub(nn) else point.add(nn);

        var shadow_pt: Vec3f = undefined;
        var shadow_n: Vec3f = undefined;
        var _unused: Material = undefined;
        if (sceneIntersect(shadow_origin, light_dir, spheres, &shadow_pt, &shadow_n, &_unused) and shadow_pt.sub(shadow_origin).norm() < light_distance) {
            continue;
        }

        diffuse_light_intensity += l.intensity * std.math.max(0, light_dir.mul(normal));
        specular_light_intensity += std.math.pow(f32, std.math.max(0, -reflect(light_dir.negate(), normal).mul(direction)), material.specular_exponent) * l.intensity;
    }

    const p1 = material.diffuse_color.mulScalar(diffuse_light_intensity * material.albedo[0]);
    const p2 = vec3(1, 1, 1).mulScalar(specular_light_intensity).mulScalar(material.albedo[1]);
    const p3 = reflect_color.mulScalar(material.albedo[2]);
    const p4 = refract_color.mulScalar(material.albedo[3]);
    return p1.add(p2.add(p3.add(p4)));
}

const width = 1024;
const height = 768;
const fov: f32 = std.math.pi / 3.0;

const RenderContext = struct {
    framebuffer: []Vec3f,
    start: usize,
    end: usize,
    spheres: []const Sphere,
    lights: []const Light,
};

fn outputFramebufferPpm(framebuffer: []Vec3f) !void {
    var stdout_file = try std.io.getStdOut();
    const stdout = &stdout_file.outStream().stream;
    try stdout.print("P6\n{} {}\n255\n", @intCast(usize, width), @intCast(usize, height));

    var i: usize = 0;
    for (framebuffer) |*c| {
        var max = std.math.max(c.x, std.math.max(c.y, c.z));
        if (max > 1) c.* = c.mulScalar(1 / max);

        const T = @typeInfo(Vec3f).Struct;
        inline for (T.fields) |field| {
            try stdout.print("{c}", @floatToInt(u8, 255 * std.math.max(0, std.math.min(1, @field(c, field.name)))));
        }
    }
}

fn renderFramebufferSegment(context: RenderContext) void {
    var j: usize = context.start;
    while (j < context.end) : (j += 1) {
        var i: usize = 0;
        while (i < width) : (i += 1) {
            const x = (2 * (@intToFloat(f32, i) + 0.5) / width - 1) * std.math.tan(fov / 2.0) * width / height;
            const y = -(2 * (@intToFloat(f32, j) + 0.5) / height - 1) * std.math.tan(fov / 2.0);

            const direction = vec3(x, y, -1).normalize();
            context.framebuffer[i + j * width] = castRay(vec3(0, 0, 0), direction, context.spheres, context.lights, 0);
        }
    }
}

fn renderMulti(allocator: *std.mem.Allocator, spheres: []const Sphere, lights: []const Light) !void {
    var framebuffer = std.ArrayList(Vec3f).init(allocator);
    defer framebuffer.deinit();
    try framebuffer.resize(width * height);

    const cpu_count = try std.os.cpuCount(allocator);
    const batch_size = height / cpu_count;

    var threads = std.ArrayList(*std.os.Thread).init(allocator);
    defer threads.deinit();

    var j: usize = 0;
    while (j < height) : (j += batch_size) {
        const context = RenderContext{
            .framebuffer = framebuffer.toSlice(),
            .start = j,
            .end = j + batch_size,
            .spheres = spheres,
            .lights = lights,
        };

        try threads.append(try std.os.spawnThread(context, renderFramebufferSegment));
    }

    for (threads.toSliceConst()) |thread| {
        thread.wait();
    }

    try outputFramebufferPpm(framebuffer.toSlice());
}

fn render(allocator: *std.mem.Allocator, spheres: []const Sphere, lights: []const Light) !void {
    var framebuffer = std.ArrayList(Vec3f).init(allocator);
    defer framebuffer.deinit();
    try framebuffer.resize(width * height);

    var j: usize = 0;
    while (j < height) : (j += 1) {
        var i: usize = 0;
        while (i < width) : (i += 1) {
            const x = (2 * (@intToFloat(f32, i) + 0.5) / width - 1) * std.math.tan(fov / 2.0) * width / height;
            const y = -(2 * (@intToFloat(f32, j) + 0.5) / height - 1) * std.math.tan(fov / 2.0);

            const direction = vec3(x, y, -1).normalize();
            framebuffer.set(i + j * width, castRay(vec3(0, 0, 0), direction, spheres, lights, 0));
        }
    }

    try outputFramebufferPpm(framebuffer.toSlice());
}

pub fn main() !void {
    const ivory = Material{
        .refractive_index = 1.0,
        .albedo = []f32{ 0.6, 0.3, 0.1, 0.0 },
        .diffuse_color = vec3(0.4, 0.4, 0.3),
        .specular_exponent = 50,
    };

    const glass = Material{
        .refractive_index = 1.5,
        .albedo = []f32{ 0.0, 0.5, 0.1, 0.8 },
        .diffuse_color = vec3(0.6, 0.7, 0.8),
        .specular_exponent = 125,
    };

    const red_rubber = Material{
        .refractive_index = 1.0,
        .albedo = []f32{ 0.9, 0.1, 0.0, 0.0 },
        .diffuse_color = vec3(0.3, 0.1, 0.1),
        .specular_exponent = 10,
    };

    const mirror = Material{
        .refractive_index = 1.0,
        .albedo = []f32{ 0.0, 10.0, 0.8, 0.0 },
        .diffuse_color = vec3(1.0, 1.0, 1.0),
        .specular_exponent = 1425,
    };

    const spheres = []const Sphere{
        Sphere{
            .center = vec3(-3, 0, -16),
            .radius = 1.3,
            .material = ivory,
        },
        Sphere{
            .center = vec3(3, -1.5, -12),
            .radius = 2,
            .material = glass,
        },
        Sphere{
            .center = vec3(1.5, -0.5, -18),
            .radius = 3,
            .material = red_rubber,
        },
        Sphere{
            .center = vec3(9, 5, -18),
            .radius = 3.7,
            .material = mirror,
        },
    };

    const lights = []const Light{
        Light{
            .position = vec3(-10, 23, 20),
            .intensity = 1.1,
        },
        Light{
            .position = vec3(17, 50, -25),
            .intensity = 1.8,
        },
        Light{
            .position = vec3(30, 20, 30),
            .intensity = 1.7,
        },
    };

    var direct = std.heap.DirectAllocator.init();
    if (multithread) {
        try renderMulti(&direct.allocator, spheres, lights);
    } else {
        try render(&direct.allocator, spheres, lights);
    }
}
