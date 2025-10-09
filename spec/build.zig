const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const options = b.addOptions();
    const filter = b.option(
        []const u8,
        "filter",
        "Filter benchmark(s) to this string",
    ) orelse &.{};
    options.addOption([]const u8, "filter", filter);

    const z2d_dep = b.dependency("z2d", .{
        .target = target,
        .optimize = optimize,
    });
    const zbench_dep = b.dependency("zbench", .{
        .target = target,
        .optimize = optimize,
    });
    const spec_bench_mod = b.addModule("spec_bench", .{
        .root_source_file = b.path("main_bench.zig"),
        .target = target,
        .optimize = optimize,
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
