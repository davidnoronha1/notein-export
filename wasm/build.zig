const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    // WASM artifact: freestanding, no libc, no OS.
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });

    const wasm_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = wasm_target,
        .optimize = optimize,
    });

    const strip = b.option(bool, "strip", "Strip debug symbols") orelse (optimize != .debug);

    const wasm = b.addExecutable(.{
        .name = "notein",
        .root_module = wasm_mod,
    });
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    wasm.import_memory = false;
    wasm.root_module.strip = strip;

    const wasm_out = b.addInstallArtifact(wasm, .{
        .dest_dir = .{ .override = .{ .custom = "../../web/src/wasm" } },
    });
    b.getInstallStep().dependOn(&wasm_out.step);

    // Native test artifact: full std available (OS/file I/O) for fixture-backed tests.
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    const tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
