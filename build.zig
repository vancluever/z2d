// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024 Chris Marchesi
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    /////////////////////////////////////////////////////////////////////////
    // Main module
    /////////////////////////////////////////////////////////////////////////
    const z2d = b.addModule("z2d", .{
        .root_source_file = b.path("src/z2d.zig"),
    });

    /////////////////////////////////////////////////////////////////////////
    // Unit tests
    /////////////////////////////////////////////////////////////////////////
    const test_run = b.addRunArtifact(b.addTest(.{
        .root_source_file = b.path("src/z2d.zig"),
        .target = target,
        .optimize = .Debug,
    }));
    b.step("test", "Run unit tests").dependOn(&test_run.step);

    /////////////////////////////////////////////////////////////////////////
    // Spec tests
    //
    // Spec tests are complex E2E tests that render to files for comparison.
    // Use "zig build spec -Dupdate=true" to generate the files used by this
    // test. The test code itself is found in "spec".
    /////////////////////////////////////////////////////////////////////////
    const spec_update = b.option(
        bool,
        "update",
        "Update spec (E2E) tests (needs to be run with the \"spec\" target)",
    );
    const spec_test = spec: {
        const opts = .{
            .name = "spec",
            .root_source_file = b.path("spec/main.zig"),
            .target = target,
            .optimize = .Debug,
        };
        if (spec_update orelse false)
            break :spec b.addExecutable(opts)
        else
            break :spec b.addTest(opts);
    };
    spec_test.root_module.addImport("z2d", z2d);
    const spec_run = b.addRunArtifact(spec_test);
    b.step("spec", "Run spec (E2E) tests").dependOn(&spec_run.step);

    /////////////////////////////////////////////////////////////////////////
    // Docs
    //
    // Docs are generated with autodoc and need to be hosted with a webserver.
    // You can run a simple webserver from the CLI if you have python:
    //
    //   cd zig-out/docs && python3 -m http.server
    //
    /////////////////////////////////////////////////////////////////////////
    const docs_build = b.addInstallDirectory(.{
        .install_dir = .prefix,
        .install_subdir = "docs/z2d",
        .source_dir = b.addObject(.{
            .name = "z2d",
            .root_source_file = b.path("src/z2d.zig"),
            .target = target,
            .optimize = .Debug,
        }).getEmittedDocs(),
    });
    b.step("docs", "Build documentation").dependOn(&docs_build.step);
}
