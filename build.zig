const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main module
    const z2d = b.addModule("z2d", .{ .root_source_file = .{ .path = "src/z2d.zig" } });

    // Tests
    const main_test = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    const test_run = b.addRunArtifact(main_test);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&test_run.step);

    // Spec tests are complex E2E tests that render to files for comparison.
    // Use "zig build spec -Dupdate=true" to generate the files used by this test. The
    // test code itself is found in "spec".
    const spec_update = b.option(
        bool,
        "update",
        "Update spec (E2E) tests (needs to be run with the \"spec\" target",
    );
    const spec_test = spec: {
        const opts = .{
            .name = "spec",
            .root_source_file = .{ .path = "spec/main.zig" },
            .target = target,
            .optimize = optimize,
        };
        if (spec_update orelse false)
            break :spec b.addExecutable(opts)
        else
            break :spec b.addTest(opts);
    };

    spec_test.root_module.addImport("z2d", z2d);
    const spec_test_run = b.addRunArtifact(spec_test);
    const spec_test_step = b.step("spec", "Run spec (E2E) tests");
    spec_test_step.dependOn(&spec_test_run.step);
}
