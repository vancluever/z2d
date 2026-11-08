const std = @import("std");
const z2d_build = @import("z2d");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const options = b.addOptions();
    const filter = b.option(
        []const u8,
        "filter",
        "Filter benchmark(s) to this string",
    );
    const link_libc = b.option(
        bool,
        "use_libc",
        "Use libc (affects allocations) (default=false)",
    ) orelse false;
    options.addOption(?[]const u8, "filter", filter);
    options.addOption(bool, "link_libc", link_libc);

    const simd = b.option(
        bool,
        "simd",
        "Enables SIMD (vectorized) code where available (default=true)",
    ) orelse true;

    const float_precision = b.option(
        z2d_build.FloatPrecision,
        "float_precision",
        "Precision of geometry-based floating-point operations (default=double)",
    ) orelse .double;

    const z2d_dep = b.dependency("z2d", .{
        .target = target,
        .optimize = optimize,
        .simd = simd,
        .float_precision = float_precision,
    });
    const zbench_dep = b.dependency("zbench", .{
        .target = target,
        .optimize = optimize,
    });
    const spec_bench_mod = b.addModule("spec_bench", .{
        .root_source_file = b.path("main_bench.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = link_libc,
    });
    spec_bench_mod.addOptions("options", options);
    spec_bench_mod.addImport("z2d", z2d_dep.module("z2d"));
    spec_bench_mod.addImport("zbench", zbench_dep.module("zbench"));
    const spec_bench = b.addExecutable(.{
        .name = "spec-bench",
        .root_module = spec_bench_mod,
    });
    const spec_bench_run = b.addRunArtifact(spec_bench);
    b.step("bench", "Run benchmarks (default)").dependOn(&spec_bench_run.step);
    b.default_step = &spec_bench_run.step;
}
