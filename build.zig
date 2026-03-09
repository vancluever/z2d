// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024-2025 Chris Marchesi
const std = @import("std");
const builtin = @import("builtin");

/// Returns a step that generates our documentation, with all unnecessary
/// dependencies filtered out (currently this is "std" and "builtin").
///
/// NOTE: This relies on system tools right now, but eventually once the stdlib
/// gets better, I'd love to move this to pure Zig.
pub fn docsStep(
    b: *std.Build,
    mod: *std.Build.Module,
) *std.Build.Step {
    const dir = b.addInstallDirectory(.{
        .source_dir = b.addObject(.{
            .name = "z2d",
            .root_module = mod,
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
        b.fmt("cat {s} | tar --delete std > {s}", .{ in_tar, out_tar }),
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

/// A step that runs kcov on an artifact binary (requires kcov to be
/// installed).
pub fn coverStep(b: *std.Build, artifact: *std.Build.Step.Compile, clean: bool) *std.Build.Step {
    const dir = b.pathJoin(
        &.{ b.install_prefix, "cover" },
    );

    const coverage_command = b.addSystemCommand(&.{ "kcov", "--clean", "--include-pattern=z2d", dir });
    coverage_command.addArtifactArg(artifact);

    if (clean) {
        const clean_command = b.addSystemCommand(&.{ "rm", "-rf", dir });
        coverage_command.step.dependOn(&clean_command.step);
    }

    const open_command = b.addSystemCommand(&.{
        if (builtin.target.os.tag == .linux) "xdg-open" else "open",
        b.pathJoin(&.{ dir, "index.html" }),
    });

    open_command.step.dependOn(&coverage_command.step);
    return &open_command.step;
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
        .optimize = optimize,
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
    const llvm = b.option(
        bool,
        "llvm",
        "Override use of llvm in tests (default: test=false, spec=true)",
    );
    const cover = b.option(
        bool,
        "cover",
        "Generate and open coverage report for test or spec steps (implies llvm=true)",
    ) orelse false;
    const clean = b.option(
        bool,
        "clean",
        "Clean coverage directory when running",
    ) orelse false;
    const test_compile = b.addTest(.{
        .root_module = z2d,
        .filters = test_filters,
        .use_llvm = if (cover) true else llvm orelse false,
    });
    const test_step = b.step("test", "Run unit tests");
    if (cover) {
        const cover_step = coverStep(b, test_compile, clean);
        test_step.dependOn(cover_step);
    } else {
        const test_run = b.addRunArtifact(test_compile);
        test_step.dependOn(&test_run.step);
    }
    var check_step = b.step("check", "Build, but don't run, unit tests");
    check_step.dependOn(&test_compile.step);

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

    const z2d_spec = b.addModule("z2d_spec", .{
        .root_source_file = b.path("spec/main_spec.zig"),
        .target = target,
        .optimize = optimize,
    });

    const spec_test = spec: {
        if (spec_update orelse false)
            break :spec b.addExecutable(.{
                .name = "spec",
                .root_module = z2d_spec,
                .use_llvm = llvm orelse true,
            })
        else
            break :spec b.addTest(.{
                .name = "spec",
                .root_module = z2d_spec,
                .filters = test_filters,
                .use_llvm = llvm orelse true,
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
    const docs_step = docsStep(b, z2d);
    b.step("docs", "Generate documentation").dependOn(docs_step);
    b.step("docs-serve", "Serve documentation").dependOn(docsServeStep(b, docs_step));
    b.step("docs-bundle", "Bundle documentation").dependOn(docsBundleStep(b, docs_step));
}
