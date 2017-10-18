const std = @import("std");
const math = std.math;
const os = std.os;
const mem = std.mem;
const printf = std.io.stdout.printf;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Buffer = std.Buffer;
const InStream = std.io.InStream;

// NOTE: Allow passing custom build variables.
//
// zig build -Duse_threads=true
//
// const use_threads = @buildVar("use-threads");
//
// A @buildVar would have to be specified within `build.zig` and must have a default
// value. If not using a build script, require -Duse-threads=...
//
// Alternatively, you could have a fallback at use but that would not be so clean as
// it allows different local build preferences to be specified.
const use_threads = false;

const libc = @cImport({
    @cInclude("stdio.h");
    if (use_threads) {
        // C11 Threads aren't supported in GCC
        const l = @cInclude("tinycthread.h");
    }
});

fn Array2d(comptime T: type) -> type { struct {
    const Self = this;

    allocator: &Allocator,
    items: []T,
    w: usize,
    h: usize,

    pub fn init(a: &Allocator, w: usize, h: usize) -> %Self {
        Self {
            .allocator = a,
            .items = %return a.alloc(T, w * h),
            .w = w,
            .h = h,
        }
    }

    pub fn deinit(self: &Self) {
        self.allocator.free(self.items);
    }

    pub fn row(self: &const Self, n: usize) -> []T {
        std.debug.assert(n < self.h);
        const offset = n * self.w;
        self.items[offset .. offset + self.w]
    }

    pub fn at(self: &const Self, x: usize, y: usize) -> &T {
        std.debug.assert(x < self.w and y < self.h);
        &self.items[y * self.w + x]
    }
}}

const Vec3 = struct {
    x: f32,
    y: f32,
    z: f32,

    pub fn add(lhs: &const Vec3, rhs: &const Vec3) -> Vec3 {
        Vec3 { .x = lhs.x + rhs.x, .y = lhs.y + rhs.y, .z = lhs.z + rhs.z }
    }

    pub fn sub(lhs: &const Vec3, rhs: &const Vec3) -> Vec3 {
        Vec3 { .x = lhs.x - rhs.x, .y = lhs.y - rhs.y, .z = lhs.z - rhs.z }
    }

    pub fn mul(lhs: &const Vec3, scalar: f32) -> Vec3 {
        Vec3 { .x = lhs.x * scalar, .y = lhs.y * scalar, .z = lhs.z * scalar }
    }

    pub fn dot(lhs: &const Vec3, rhs: &const Vec3) -> f32 {
        lhs.x * rhs.x + lhs.y * rhs.y + lhs.z * rhs.z
    }

    pub fn cross(lhs: &const Vec3, rhs: &const Vec3) -> Vec3 {
        Vec3 {
            .x = lhs.y * rhs.z - lhs.z * rhs.y,
            .y = lhs.z * rhs.x - lhs.x * rhs.z,
            .z = lhs.x * rhs.y - lhs.x * rhs.y,
        }
    }

    pub fn magnitude(lhs: &const Vec3) -> f32 {
        math.sqrt(lhs.dot(lhs))
    }

    pub fn unit(lhs: &const Vec3) -> Vec3 {
        lhs.mul(1 / lhs.magnitude())
    }

    pub fn isUnit(lhs: &const Vec3) -> bool {
        lhs.magnitude() == 1
    }
};

const Image = Array2d(Pixel);
const Color = struct { r: u8, g: u8, b: u8 };
const Pixel = Color;
const Ray = struct { origin: Vec3, direction: Vec3 };

const Object = struct {
    origin: Vec3,
    radius: f32,

    // Add transparency, reflectivity, surface color, emission color
    color: Color,
};

fn intersectDist(ray: &const Ray, sphere: &const Object) -> ?f32 {
    std.debug.assert(ray.direction.isUnit());

    const rms = Vec3.sub(&ray.origin, &sphere.origin);
    // a cancels out entirely and can be omitted
    const b = Vec3.dot(&ray.direction, &rms);
    const c = Vec3.dot(&rms, &rms) - sphere.radius * sphere.radius;

    const disc = b * b - c;
    const min = 0.01;

    // 2 solutions, want least positive
    if (disc > 0) {
        const s1 = -b - disc;
        const s2 = -b + disc;

        if (s1 > min and s2 > min) {
            math.min(s1, s2)
        } else if (s1 > min) {
            s1
        } else if (s2 > min) {
            s2
        } else {
            null
        }
    }
    // 1 solution, want if positive
    else if (disc == 0) {
        const s1 = -b;

        if (s1 > min) {
            s1
        } else {
            null
        }
    }
    // 0 solutions
    else {
        null
    }
}

fn traceRay(ray: &const Ray, objects: []const Object, depth: usize) -> Color {
    var object_near: ?Object = null;
    var t_near = math.inf(f32);

    for (objects) |object| {
        if (intersectDist(ray, &object)) |t0| {
            if (t0 < t_near) {
                object_near = object;
                t_near = t0;
            }
        }
    }

    if (object_near) |o| {
        // NOTE: We don't shoot any sub-rays since we don't yet have any light sources
        const scale = 0.8 / math.max(f32(1.0), t_near) + 0.2;

        Color {
            .r = u8(f32(o.color.r) * scale),
            .g = u8(f32(o.color.g) * scale),
            .b = u8(f32(o.color.b) * scale),
        }
    } else {
        Color { .r = 0, .g = 0, .b = 0 }
    }
}

const scaleX: f32 = 4.0;
const scaleY: f32 = 4.0;
// start position from top-left
const startX: f32 = -2.0;
const startY: f32 = 2.0;

fn traceSingle(image: &Image, spheres: []const Object) {
    var y: usize = 0; while (y < image.h) : (y += 1) {
        var x: usize = 0; while (x < image.w) : (x += 1) {
            const xx = startX + scaleX * (f32(x) / f32(image.w));
            const yy = startY - scaleY * (f32(y) / f32(image.h));

            // perpendicular projection
            const ray = Ray {
                .origin = Vec3 { .x = xx, .y = yy, .z = -1, },
                .direction = (Vec3 { .x = 0, .y = 0, .z = 1, }).unit(),
            };

            *image.at(x, y) = traceRay(&ray, spheres, 0);
        }
    }
}

// Setting to 0 should ensure no space is used for the trace_thread_data array when single-threaded.
const thread_count = if (use_threads) 8 else 0;
const ThreadArg = struct { lo: usize, hi: usize, image: &Image, spheres: []const Object };
var thread_work_data: [thread_count]ThreadArg = undefined;

extern fn traceMultiPart(arg: ?&c_void) -> c_int {
    const aligned_arg = @alignCast(@alignOf(ThreadArg), arg);
    var args = *@ptrCast(&const ThreadArg, aligned_arg);

    var y = args.lo; while (y < args.hi) : (y += 1) {
        var x: usize = 0; while (x < args.image.w) : (x += 1) {
            const xx = startX + scaleX * (f32(x) / f32(args.image.w));
            const yy = startY - scaleY * (f32(y) / f32(args.image.h));

            // perpendicular projection
            const ray = Ray {
                .origin = Vec3 { .x = xx, .y = yy, .z = -1, },
                .direction = (Vec3 { .x = 0, .y = 0, .z = 1, }).unit(),
            };

            *args.image.at(x, y) = traceRay(&ray, args.spheres, 0);
        }
    }

    0
}

fn traceMulti(image: &Image, spheres: []const Object) {
    var threads: [thread_count]libc.thrd_t = undefined;

    for (threads) |*t, i| {
        const segment_size = image.h / thread_count;
        const segment = i * segment_size;

        // Pre-assign block of work in rows.
        thread_work_data[i] = ThreadArg {
            .lo = i * segment_size,
            .hi = if (i + 1 == thread_count) {
                // Since the first division truncates we may have cut the final segment short.
                // Extend it to take the remaining space.
                image.h
            } else {
                (i + 1) * segment_size
            },
            .image = image,
            .spheres = spheres
        };

        if (libc.thrd_create(t, traceMultiPart, @ptrCast(&c_void, &thread_work_data[i])) != libc.thrd_success) {
            // Correct cleanup here is really messy (condition variables in callee code and more).
            std.os.abort();
        }
    }

    for (threads) |t| {
        _ = libc.thrd_join(t, null);
    }
}

const trace = if (use_threads) traceMulti else traceSingle;

fn writePpm(image: &const Image) -> %void {
    %return printf(
        \\P3
        \\{}
        \\{}
        \\255
        \\
        , image.w
        , image.h
    );

    var i: usize = 0; while (i < image.h) : (i += 1) {
        for (image.row(i)) |pixel| {
            %return printf(" {} {} {}", pixel.r, pixel.g, pixel.b);
        }
        %return printf("\n");
    }
}

error ParseLine;
fn readObjectListFile(filename: []const u8) -> %ArrayList(Object) {
    var fd = %return InStream.open(filename, &mem.c_allocator);
    defer fd.close();

    var buf = Buffer.initNull(&mem.c_allocator);
    defer buf.deinit();

    %return fd.readAll(&buf);

    var list = ArrayList(Object).init(&mem.c_allocator);
    %defer list.deinit();

    var lines = std.mem.split(buf.toSliceConst(), "\n");
    while (lines.next()) |line| {
        // line isn't necessarily null-terminated so do this ourselves
        var c_line = %return Buffer.init(&mem.c_allocator, line);
        defer c_line.deinit();

        var o: Object = undefined;
        // NOTE: Can we get a nice simple sscanf alternative in zig?
        //
        // Use a compile-time string similar to printf and emit
        // a series of primitive reads.
        if (libc.sscanf(&c_line.toSlice()[0], c"%f %f %f %f %u %u %u\n",
            &o.origin.x,
            &o.origin.y,
            &o.origin.z,
            &o.radius,
            &o.color.r,
            &o.color.g,
            &o.color.b) != 7)
        {
            return error.ParseLine;
        }

        %return list.append(o);
    }

    list
}

error NoFileProvided;
pub fn main() -> %void {
    // We currently stretch the view to match the image size
    // We use a square reference but should maintain an aspect ratio
    var image = %%Image.init(&mem.c_allocator, 512, 512);
    defer image.deinit();

    var args = os.args();
    const program_name = ??args.next(&mem.c_allocator);

    var filename = if (args.next(&mem.c_allocator)) |arg| {
        %%arg
    } else {
        %%std.io.stderr.printf("usage: {} [file]\n", program_name);
        return;
    };

    var objects = %%readObjectListFile(filename);
    trace(&image, objects.toSliceConst());
    %%writePpm(&image);
}
