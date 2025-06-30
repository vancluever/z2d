// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024-2025 Chris Marchesi
const std = @import("std");

/// Returns a step that generates our documentation, with all unnecessary
/// dependencies filtered out (currently this is "std" and "builtin").
///
/// NOTE: This relies on system tools right now, but eventually once the stdlib
/// gets better, I'd love to move this to pure Zig.
pub fn docsStep(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
) *std.Build.Step {
    const dir = b.addInstallDirectory(.{
        .source_dir = b.addObject(.{
            .name = "z2d",
            .root_source_file = b.path("src/z2d.zig"),
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
    const tar = b.addSystemCommand(&.{"sh"});
    tar.addArgs(&.{
        "-c",
        b.fmt("cat {s} | tar --delete std builtin > {s}", .{ in_tar, out_tar }),
    });

    const mv = b.addSystemCommand(&.{ "mv", out_tar, in_tar });

    tar.step.dependOn(&dir.step);
    mv.step.dependOn(&tar.step);
    return &mv.step;
}

/// Serves the "docs" directory. Relies on python3 being installed.
///
/// NOTE: This relies on system tools right now, but eventually once the stdlib
/// gets better, I'd love to move this to pure Zig.
pub fn docsServeStep(b: *std.Build, docs_step: *std.Build.Step) *std.Build.Step {
    const server = b.addSystemCommand(&.{ "python3", "-m", "http.server" });
    // No idea how to access the build prefix otherwise right now, so we have
    // to set this manually
    server.setCwd(.{ .cwd_relative = b.pathJoin(&.{ b.install_prefix, "docs" }) });
    server.step.dependOn(docs_step);
    return &server.step;
}

/// Bundles the documentation into a z2d-docs.tar.gz file in zig-out.
///
/// NOTE: This relies on system tools right now, but eventually once the stdlib
/// gets better, I'd love to move this to pure Zig.
///
/// If branch is specified, ensures that main.js, main.wasm, and sources.tar
/// reference that branch.
pub fn docsBundleStep(b: *std.Build, docs_step: *std.Build.Step) *std.Build.Step {
    const dir = b.pathJoin(
        &.{ b.install_prefix, "docs" },
    );
    const target = b.pathJoin(
        &.{ b.install_prefix, "z2d-docs.tar.gz" },
    );
    const tar = b.addSystemCommand(&.{
        "tar",
        "--create",
        "--gzip",
        b.fmt("--directory={s}", .{dir}),
        b.fmt("--file={s}", .{target}),
        ".",
    });

    const main_js_sed = b.addSystemCommand(&.{
        "sed",
        "--in-place",
        "s#main.js#/docs/main.js#g",
        b.pathJoin(&.{ dir, "index.html" }),
    });
    const main_wasm_sed = b.addSystemCommand(&.{
        "sed",
        "--in-place",
        "s#main.wasm#/docs/main.wasm#g",
        b.pathJoin(&.{ dir, "main.js" }),
    });
    const sources_tar_sed = b.addSystemCommand(&.{
        "sed",
        "--in-place",
        "s#sources.tar#/docs/sources.tar#g",
        b.pathJoin(&.{ dir, "main.js" }),
    });
    main_js_sed.step.dependOn(docs_step);
    main_wasm_sed.step.dependOn(&main_js_sed.step);
    sources_tar_sed.step.dependOn(&main_wasm_sed.step);
    tar.step.dependOn(&sources_tar_sed.step);
    return &tar.step;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    /////////////////////////////////////////////////////////////////////////
    // Module build options
    //
    // All module build options are documented in src/z2d.zig.
    /////////////////////////////////////////////////////////////////////////
    const z2d_options = b.addOptions();
    const vector_length = b.option(
        u32,
        "vector_length",
        "Length of vector operations (default=16)",
    ) orelse 16;
    z2d_options.addOption(u32, "vector_length", vector_length);

    /////////////////////////////////////////////////////////////////////////
    // Main module
    /////////////////////////////////////////////////////////////////////////
    const z2d = b.addModule("z2d", .{
        .root_source_file = b.path("src/z2d.zig"),
        .target = target,
    });
    z2d.addOptions("z2d_options", z2d_options);

    /////////////////////////////////////////////////////////////////////////
    // Unit tests
    /////////////////////////////////////////////////////////////////////////
    const test_filters = b.option(
        [][]const u8,
        "filter",
        "Test filter for \"test\" or \"spec\" target (repeat for multiple filters)",
    ) orelse &[0][]const u8{};
    const test_step = b.addTest(.{
        .root_module = z2d,
        .target = target,
        .optimize = optimize,
        .filters = test_filters,
    });
    const test_run = b.addRunArtifact(test_step);
    b.step("test", "Run unit tests").dependOn(&test_run.step);
    var check_step = b.step("check", "Build, but don't run, unit tests");
    check_step.dependOn(&test_step.step);

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
        if (spec_update orelse false)
            break :spec b.addExecutable(.{
                .name = "spec",
                .root_source_file = b.path("spec/main.zig"),
                .target = target,
                .optimize = optimize,
            })
        else
            break :spec b.addTest(.{
                .name = "spec",
                .root_source_file = b.path("spec/main.zig"),
                .target = target,
                .optimize = optimize,
                .filters = test_filters,
            });
    };
    spec_test.root_module.addImport("z2d", z2d);
    const spec_options = b.addOptions();
    spec_test.root_module.addOptions("spec_options", spec_options);
    const spec_run = b.addRunArtifact(spec_test);
    b.step("spec", "Run spec (E2E) tests").dependOn(&spec_run.step);
    check_step.dependOn(&spec_test.step);

    /////////////////////////////////////////////////////////////////////////
    // Release automation
    /////////////////////////////////////////////////////////////////////////
    const release_cmd = b.addSystemCommand(&.{"build-support/scripts/release.sh"});
    b.step("release", "Tag and push a release").dependOn(&release_cmd.step);

    /////////////////////////////////////////////////////////////////////////
    // Docs
    /////////////////////////////////////////////////////////////////////////
    const docs_step = docsStep(b, target);
    b.step("docs", "Generate documentation").dependOn(docs_step);
    b.step("docs-serve", "Serve documentation").dependOn(docsServeStep(b, docs_step));
    b.step("docs-bundle", "Bundle documentation").dependOn(docsBundleStep(b, docs_step));
}
