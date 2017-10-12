const stdbuild = @import("std").build;
const Builder = stdbuild.Builder;
const LibExeObjStep = stdbuild.LibExeObjStep;

// NOTE: Some things to resolve on the threading library integration first
const use_threads = false;

fn buildSingle(b: &Builder) -> &LibExeObjStep {
    var exe = b.addExecutable("raytrace", "main.zig");

    exe.linkSystemLibrary("c");
    exe
}

fn buildMulti(b: &Builder) -> &LibExeObjStep {
    var exe = b.addCExecutable("raytrace");
    b.addCIncludePath("./deps");

    exe.linkSystemLibrary("c");
    exe.linkSystemLibrary("pthread");

    const c_source = [][]const u8 {
        "./deps/tinycthread.c",
    };

    for (c_source) |source| {
        exe.addSourceFile(source);
    }

    const zig_source = [][]const u8 {
        "main.zig",
    };

    for (zig_source) |source| {
        const object = b.addObject(source, source);
        exe.addObject(object);
    }

    exe
}

pub fn build(b: &Builder) {
    const mode = b.standardReleaseOptions();
    var exe = if (!use_threads) buildSingle(b) else buildMulti(b);

    exe.setBuildMode(mode);
    exe.setOutputPath("./raytrace");
    b.default_step.dependOn(&exe.step);
    b.installArtifact(exe);
}
