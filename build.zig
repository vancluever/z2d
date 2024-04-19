// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024 Chris Marchesi
const std = @import("std");

/// Returns a step that generates our documentation, with all unnecessary
/// dependencies filtered out (currently this is "std" and "builtin").
///
/// NOTE: This relies on system tools right now, but eventually once the stdlib
/// gets better, I'd love to move this to pure Zig.
pub fn docsStep(
    b: *std.Build,
    vendor_prefix: []const u8,
    target: std.Build.ResolvedTarget,
) *std.Build.Step {
    const dir = b.addInstallDirectory(.{
        .source_dir = b.addObject(.{
            .name = "z2d",
            .root_source_file = b.path(b.pathJoin(&.{ vendor_prefix, "src/z2d.zig" })),
            .target = target,
            .optimize = .Debug,
        }).getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    const in_tar = b.pathJoin(
        &.{ b.install_prefix, "docs", "sources.tar" },
    );
    const out_tar = b.pathJoin(
        &.{ b.install_prefix, "docs", "sources.tar.new" },
    );
    const tar_fmt =
        \\cat {s} | tar --delete std builtin > {s}
        \\mv {s} {s}
    ;
    const tar = b.addSystemCommand(&.{"sh"});
    tar.addArgs(&.{
        "-c",
        b.fmt(tar_fmt, .{ in_tar, out_tar, out_tar, in_tar }),
    });

    tar.step.dependOn(&dir.step);
    return &tar.step;
}

/// Serves the "docs" directory. Relies on python3 being installed.
///
/// NOTE: This relies on system tools right now, but eventually once the stdlib
/// gets better, I'd love to move this to pure Zig.
pub fn docsServeStep(b: *std.Build, docs_step: *std.Build.Step) *std.Build.Step {
    const server = b.addSystemCommand(&.{ "python3", "-m", "http.server" });
    // No idea how to access the build prefix otherwise right now, so we have
    // to set this manually
    server.setCwd(.{ .path = b.pathJoin(&.{ b.install_prefix, "docs" }) });
    server.step.dependOn(docs_step);
    return &server.step;
}

/// Bundles the documentation into a z2d-docs.tar.gz file in zig-out.
///
/// NOTE: This relies on system tools right now, but eventually once the stdlib
/// gets better, I'd love to move this to pure Zig.
pub fn docsBundleStep(b: *std.Build, docs_step: *std.Build.Step) *std.Build.Step {
    const dir = b.pathJoin(
        &.{ b.install_prefix, "docs" },
    );
    const target = b.pathJoin(
        &.{ b.install_prefix, "z2d-docs.tar.gz" },
    );
    const tar = b.addSystemCommand(&.{ "tar", "-zcf", target, "-C", dir, "." });
    tar.step.dependOn(docs_step);
    return &tar.step;
}

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
    /////////////////////////////////////////////////////////////////////////a
    const docs_step = docsStep(b, "", target);
    b.step("docs", "Generate documentation").dependOn(docs_step);
    b.step("docs-serve", "Serve documentation").dependOn(docsServeStep(b, docs_step));
    b.step("docs-bundle", "Bundle documentation").dependOn(docsBundleStep(b, docs_step));
}
