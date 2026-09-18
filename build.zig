// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024-2026 Chris Marchesi
const std = @import("std");
const builtin = @import("builtin");

/// Returns a step that generates our documentation, with all unnecessary
/// dependencies filtered out (currently this is just "std").
///
/// NOTE: This relies on system tools right now, but eventually once the stdlib
/// gets better, I'd love to move this to pure Zig.
fn docsStep(
    b: *std.Build,
    mod: *std.Build.Module,
) !std.Build.LazyPath {
    const docs_dir_name = "docs-generated";

    // This should generate a directory named "z2d-docs" with the documentation
    // as emitted by getEmittedDocs. Unfortunately the name generated here
    // determines the root namespace, so we have to keep it this way; we try to
    // keep every other directory named something else unique though so that
    // things are easily identifiable in the cache.
    const emitted_docs_dir = b.addObject(.{
        .name = "z2d",
        .root_module = mod,
    }).getEmittedDocs();

    const in_tar = try emitted_docs_dir.join(b.allocator, "sources.tar");
    const tar = b.addSystemCommand(&.{"sh"});
    tar.addArgs(&.{
        "-c",
        "cat \"$1\" | tar --delete std > \"$2\"",
        "--",
    });
    tar.addFileArg(in_tar);
    const out_tar = tar.addOutputFileArg("z2d-sources.tar");

    const wf = b.addWriteFiles();
    const out_docs_dir = try wf.getDirectory().join(b.allocator, docs_dir_name);
    inline for (.{ "main.js", "main.wasm", "index.html" }) |file| {
        _ = wf.addCopyFile(
            try emitted_docs_dir.join(b.allocator, file),
            b.fmt("{s}/{s}", .{ docs_dir_name, file }),
        );
    }
    _ = wf.addCopyFile(out_tar, b.fmt("{s}/{s}", .{ docs_dir_name, "sources.tar" }));

    return out_docs_dir;
}

/// Serves the "docs" directory. Relies on python3 being installed.
///
/// NOTE: This relies on system tools right now, but eventually once the stdlib
/// gets better, I'd love to move this to pure Zig.
fn docsServeStep(b: *std.Build, docs_dir: std.Build.LazyPath) *std.Build.Step {
    const server = b.addSystemCommand(&.{ "python3", "-m", "http.server" });
    server.setCwd(docs_dir);
    return &server.step;
}

/// Bundles the documentation into a z2d-docs.tar.gz file in zig-out.
///
/// NOTE: This relies on system tools right now, but eventually once the stdlib
/// gets better, I'd love to move this to pure Zig.
fn docsBundleStep(b: *std.Build, docs_dir: std.Build.LazyPath) !*std.Build.Step {
    const out_file_name = "z2d-docs.tar.gz";
    const bundle_dir_name = "docs-bundle";

    const wf = b.addWriteFiles();
    const bundle_dir = try wf.getDirectory().join(b.allocator, bundle_dir_name);

    inline for (.{ "main.wasm", "sources.tar" }) |file| {
        _ = wf.addCopyFile(
            try docs_dir.join(b.allocator, file),
            b.fmt("{s}/{s}", .{ bundle_dir_name, file }),
        );
    }

    const index_html_sed = b.addSystemCommand(&.{
        "sed",
        "s#main.js#/docs/main.js#g",
    });
    index_html_sed.addFileArg(try docs_dir.join(b.allocator, "index.html"));
    _ = wf.addCopyFile(
        index_html_sed.captureStdOut(.{ .basename = "index.bundle.html" }),
        b.fmt("{s}/{s}", .{ bundle_dir_name, "index.html" }),
    );

    const main_js_sed = b.addSystemCommand(&.{
        "sed",
        "s#main.wasm#/docs/main.wasm#g; s#sources.tar#/docs/sources.tar#g",
    });
    main_js_sed.addFileArg(try docs_dir.join(b.allocator, "main.js"));
    _ = wf.addCopyFile(
        main_js_sed.captureStdOut(.{ .basename = "main.bundle.js" }),
        b.fmt("{s}/{s}", .{ bundle_dir_name, "main.js" }),
    );

    const tar = b.addSystemCommand(&.{
        "sh",
        "-c",
        "tar --create --gzip --directory=\"$1\" --file=\"$2\" .",
        "--",
    });
    tar.addDirectoryArg(bundle_dir);
    const out_file = tar.addOutputFileArg(out_file_name);

    const install_tar = b.addInstallFile(out_file, out_file_name);
    return &install_tar.step;
}

/// A step that runs kcov on an artifact binary (requires kcov to be
/// installed).
fn coverStep(b: *std.Build, artifact: *std.Build.Step.Compile, clean: bool) !*std.Build.Step {
    _ = clean;

    const coverage_command = b.addSystemCommand(&.{ "kcov", "--clean", "--include-pattern=z2d" });
    const output_dir = coverage_command.addOutputDirectoryArg("z2d-cover");
    coverage_command.addArtifactArg(artifact);

    const open_command = b.addSystemCommand(&.{
        if (builtin.target.os.tag == .linux) "xdg-open" else "open",
    });
    open_command.addFileArg(try output_dir.join(b.allocator, "index.html"));

    open_command.step.dependOn(&coverage_command.step);
    return &open_command.step;
}

pub fn build(b: *std.Build) !void {
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
        const cover_step = try coverStep(b, test_compile, clean);
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
    const docs_dir = try docsStep(b, z2d);
    b.step("docs-serve", "Serve documentation").dependOn(docsServeStep(b, docs_dir));
    b.step("docs-bundle", "Bundle documentation").dependOn(try docsBundleStep(b, docs_dir));
}
