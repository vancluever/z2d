// SPDX-License-Identifier: 0BSD
//   Copyright © 2024-2025 Chris Marchesi

const builtin = @import("builtin");
const debug = @import("std").debug;
const fs = @import("std").fs;
const fmt = @import("std").fmt;
const heap = @import("std").heap;
const mem = @import("std").mem;
const sha256 = @import("std").crypto.hash.sha2.Sha256;
const testing = @import("std").testing;

const z2d = @import("z2d");
const zbench = @import("zbench");
const options = @import("options");

const _001_smile_rgb = @import("001_smile_rgb.zig");
const _002_smile_rgba = @import("002_smile_rgba.zig");
const _003_fill_triangle = @import("003_fill_triangle.zig");
const _004_fill_square = @import("004_fill_square.zig");
const _005_fill_trapezoid = @import("005_fill_trapezoid.zig");
const _006_fill_star_even_odd = @import("006_fill_star_even_odd.zig");
const _007_fill_bezier = @import("007_fill_bezier.zig");
const _008_stroke_triangle = @import("008_stroke_triangle.zig");
const _009_stroke_square = @import("009_stroke_square.zig");
const _010_stroke_trapezoid = @import("010_stroke_trapezoid.zig");
const _011_stroke_star = @import("011_stroke_star.zig");
const _012_stroke_bezier = @import("012_stroke_bezier.zig");
const _013_fill_combined = @import("013_fill_combined.zig");
const _014_stroke_lines = @import("014_stroke_lines.zig");
const _015_stroke_miter = @import("015_stroke_miter.zig");
const _016_fill_star_non_zero = @import("016_fill_star_non_zero.zig");
const _017_stroke_star_round = @import("017_stroke_star_round.zig");
const _018_stroke_square_spiral_round = @import("018_stroke_square_spiral_round.zig");
const _019_stroke_bevel_miterlimit = @import("019_stroke_bevel_miterlimit.zig");
const _020_stroke_lines_round_caps = @import("020_stroke_lines_round_caps.zig");
const _021_stroke_lines_square_caps = @import("021_stroke_lines_square_caps.zig");
const _022_stroke_lines_butt_caps = @import("022_stroke_lines_butt_caps.zig");
const _023_smile_alpha_mask = @import("023_smile_alpha_mask.zig");
const _024_fill_triangle_direct_cross_format = @import("024_fill_triangle_direct_cross_format.zig");
const _025_fill_diamond_clipped = @import("025_fill_diamond_clipped.zig");
const _026_fill_triangle_full = @import("026_fill_triangle_full.zig");
const _027_stroke_bezier_tolerance = @import("027_stroke_bezier_tolerance.zig");
const _028_fill_bezier_tolerance = @import("028_fill_bezier_tolerance.zig");
const _029_stroke_lines_round_caps_tolerance = @import("029_stroke_lines_round_caps_tolerance.zig");
const _030_stroke_star_round_tolerance = @import("030_stroke_star_round_tolerance.zig");
const _031_fill_quad_bezier = @import("031_fill_quad_bezier.zig");
const _032_fill_arc = @import("032_fill_arc.zig");
const _033_fill_zig_mark = @import("033_fill_zig_mark.zig");
const _034_stroke_cross = @import("034_stroke_cross.zig");
const _035_arc_command = @import("035_arc_command.zig");
const _036_stroke_colinear = @import("036_stroke_colinear.zig");
const _037_stroke_join_overlap = @import("037_stroke_join_overlap.zig");
const _038_stroke_zero_length = @import("038_stroke_zero_length.zig");
const _039_stroke_paint_extent_dontclip = @import("039_stroke_paint_extent_dontclip.zig");
const _040_stroke_corner_symmetrical = @import("040_stroke_corner_symmetrical.zig");
const _041_stroke_noop_lineto = @import("041_stroke_noop_lineto.zig");
const _042_arc_ellipses = @import("042_arc_ellipses.zig");
const _043_rect_transforms = @import("043_rect_transforms.zig");
const _044_line_transforms = @import("044_line_transforms.zig");
const _045_round_join_transforms = @import("045_round_join_transforms.zig");
const _046_fill_triangle_alpha = @import("046_fill_triangle_alpha.zig");
const _047_fill_triangle_alpha_gray = @import("047_fill_triangle_alpha_gray.zig");
const _048_fill_triangle_static = @import("048_fill_triangle_static.zig");
const _049_fill_triangle_alpha4_gray = @import("049_fill_triangle_alpha4_gray.zig");
const _050_fill_triangle_alpha2_gray = @import("050_fill_triangle_alpha2_gray.zig");
const _051_fill_triangle_alpha1_gray = @import("051_fill_triangle_alpha1_gray.zig");
const _052_fill_triangle_alpha4_gray_scaledown = @import("052_fill_triangle_alpha4_gray_scaledown.zig");
const _053_fill_triangle_alpha8_gray_scaleup = @import("053_fill_triangle_alpha8_gray_scaleup.zig");
const _054_stroke_lines_dashed = @import("054_stroke_lines_dashed.zig");
const _055_stroke_miter_dashed = @import("055_stroke_miter_dashed.zig");
const _056_stroke_star_dashed = @import("056_stroke_star_dashed.zig");
const _057_stroke_bezier_dashed = @import("057_stroke_bezier_dashed.zig");
const _058_stroke_misc_dashes = @import("058_stroke_misc_dashes.zig");
const _059_stroke_star_gradient = @import("059_stroke_star_gradient.zig");
const _060_ghostty_logo = @import("060_ghostty_logo.zig");
const _061_linear_gradient = @import("061_linear_gradient.zig");
const _062_hsl_gradient = @import("062_hsl_gradient.zig");
const _063_radial_gradient = @import("063_radial_gradient.zig");
const _064_radial_source = @import("064_radial_source.zig");
const _065_conic_gradient = @import("065_conic_gradient.zig");
const _066_conic_pie_gradient = @import("066_conic_pie_gradient.zig");
const _067_gradient_transforms = @import("067_gradient_transforms.zig");
const _068_gradient_deband = @import("068_gradient_deband.zig");
const _069_gradient_dither_context = @import("069_gradient_dither_context.zig");
const _070_compositor_ops = @import("070_compositor_ops.zig");
const _071_gamma_linear = @import("071_gamma_linear.zig");
const _072_gamma_srgb = @import("072_gamma_srgb.zig");
const _073_stroke_sameclose = @import("073_stroke_sameclose.zig");
const _074_text = @import("074_text.zig");
const _075_oob_draw_corners = @import("075_oob_draw_corners.zig");
const _076_oob_draw_sides = @import("076_oob_draw_sides.zig");
const _077_oob_draw_full_outside = @import("077_oob_draw_full_outside.zig");

//////////////////////////////////////////////////////////////////////////////

var debug_allocator: heap.DebugAllocator(.{}) = .init;

pub fn main() !void {
    const alloc, const is_debug = switch (builtin.mode) {
        // NOTE: for some reason DebugAllocator breaks zbench memory tracking,
        // so I don't really recommend running it under these modes until it's
        // fixed. Regardless, we handle this below and turn off memory tracking
        // if running in these modes.
        .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },

        // Incidentally, the SmpAllocator here seems to be a lot slower than
        // using the C allocator (at the trade-off of tying you to libc).
        // Benchmark times are much different when using it, but I don't have
        // it enabled here - depending on what way you look at it, one or the
        // other could be more realistic. This keeps the benchmarks from having
        // to link against libc though, given that nothing else in the project
        // needs it currently.
        .ReleaseFast, .ReleaseSmall => .{ heap.smp_allocator, false },
    };

    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };

    var stdout = fs.File.stdout().writerStreaming(&.{});
    var bench = zbench.Benchmark.init(alloc, .{ .track_allocations = switch (builtin.mode) {
        .Debug, .ReleaseSafe => false,
        .ReleaseFast, .ReleaseSmall => true,
    } });
    defer bench.deinit();

    try addCompositorBenchmark(&bench, _001_smile_rgb);
    try addCompositorBenchmark(&bench, _002_smile_rgba);
    try addPathBenchmark(&bench, _003_fill_triangle);
    try addPathBenchmark(&bench, _004_fill_square);
    try addPathBenchmark(&bench, _005_fill_trapezoid);
    try addPathBenchmark(&bench, _006_fill_star_even_odd);
    try addPathBenchmark(&bench, _007_fill_bezier);
    try addPathBenchmark(&bench, _008_stroke_triangle);
    try addPathBenchmark(&bench, _009_stroke_square);
    try addPathBenchmark(&bench, _010_stroke_trapezoid);
    try addPathBenchmark(&bench, _011_stroke_star);
    try addPathBenchmark(&bench, _012_stroke_bezier);
    try addPathBenchmark(&bench, _013_fill_combined);
    try addPathBenchmark(&bench, _014_stroke_lines);
    try addPathBenchmark(&bench, _015_stroke_miter);
    try addPathBenchmark(&bench, _016_fill_star_non_zero);
    try addPathBenchmark(&bench, _017_stroke_star_round);
    try addPathBenchmark(&bench, _018_stroke_square_spiral_round);
    try addPathBenchmark(&bench, _019_stroke_bevel_miterlimit);
    try addPathBenchmark(&bench, _020_stroke_lines_round_caps);
    try addPathBenchmark(&bench, _021_stroke_lines_square_caps);
    try addPathBenchmark(&bench, _022_stroke_lines_butt_caps);
    try addCompositorBenchmark(&bench, _023_smile_alpha_mask);
    try addPathBenchmark(&bench, _024_fill_triangle_direct_cross_format);
    try addPathBenchmark(&bench, _025_fill_diamond_clipped);
    try addPathBenchmark(&bench, _026_fill_triangle_full);
    try addPathBenchmark(&bench, _027_stroke_bezier_tolerance);
    try addPathBenchmark(&bench, _028_fill_bezier_tolerance);
    try addPathBenchmark(&bench, _029_stroke_lines_round_caps_tolerance);
    try addPathBenchmark(&bench, _030_stroke_star_round_tolerance);
    try addPathBenchmark(&bench, _031_fill_quad_bezier);
    try addPathBenchmark(&bench, _032_fill_arc);
    try addPathBenchmark(&bench, _033_fill_zig_mark);
    try addPathBenchmark(&bench, _034_stroke_cross);
    try addPathBenchmark(&bench, _035_arc_command);
    try addPathBenchmark(&bench, _036_stroke_colinear);
    try addPathBenchmark(&bench, _037_stroke_join_overlap);
    try addPathBenchmark(&bench, _038_stroke_zero_length);
    try addPathBenchmark(&bench, _039_stroke_paint_extent_dontclip);
    try addPathBenchmark(&bench, _040_stroke_corner_symmetrical);
    try addPathBenchmark(&bench, _041_stroke_noop_lineto);
    try addPathBenchmark(&bench, _042_arc_ellipses);
    try addPathBenchmark(&bench, _043_rect_transforms);
    try addPathBenchmark(&bench, _044_line_transforms);
    try addPathBenchmark(&bench, _045_round_join_transforms);
    try addPathBenchmark(&bench, _046_fill_triangle_alpha);
    try addPathBenchmark(&bench, _047_fill_triangle_alpha_gray);
    try addPathBenchmark(&bench, _048_fill_triangle_static);
    try addPathBenchmark(&bench, _049_fill_triangle_alpha4_gray);
    try addPathBenchmark(&bench, _050_fill_triangle_alpha2_gray);
    try addPathBenchmark(&bench, _051_fill_triangle_alpha1_gray);
    try addPathBenchmark(&bench, _052_fill_triangle_alpha4_gray_scaledown);
    try addPathBenchmark(&bench, _053_fill_triangle_alpha8_gray_scaleup);
    try addPathBenchmark(&bench, _054_stroke_lines_dashed);
    try addPathBenchmark(&bench, _055_stroke_miter_dashed);
    try addPathBenchmark(&bench, _056_stroke_star_dashed);
    try addPathBenchmark(&bench, _057_stroke_bezier_dashed);
    try addPathBenchmark(&bench, _058_stroke_misc_dashes);
    try addPathBenchmark(&bench, _059_stroke_star_gradient);
    try addPathBenchmark(&bench, _060_ghostty_logo);
    try addCompositorBenchmark(&bench, _061_linear_gradient);
    try addCompositorBenchmark(&bench, _062_hsl_gradient);
    try addCompositorBenchmark(&bench, _063_radial_gradient);
    try addPathBenchmark(&bench, _064_radial_source);
    try addCompositorBenchmark(&bench, _065_conic_gradient);
    try addPathBenchmark(&bench, _066_conic_pie_gradient);
    try addPathBenchmark(&bench, _067_gradient_transforms);
    try addCompositorBenchmark(&bench, _068_gradient_deband);
    try addPathBenchmark(&bench, _069_gradient_dither_context);
    try addPathBenchmark(&bench, _070_compositor_ops);
    try addCompositorBenchmark(&bench, _071_gamma_linear);
    try addCompositorBenchmark(&bench, _072_gamma_srgb);
    try addPathBenchmark(&bench, _073_stroke_sameclose);

    // NOTE: something completely breaks memory tracking for the text test -
    // unless it's actually using 16 PiB, which something tells me it's not. ;)
    try addPathBenchmark(&bench, _074_text);

    try addPathBenchmark(&bench, _075_oob_draw_corners);
    try addPathBenchmark(&bench, _076_oob_draw_sides);
    try addPathBenchmark(&bench, _077_oob_draw_full_outside);

    try bench.run(&stdout.interface);
}

fn addCompositorBenchmark(bench: *zbench.Benchmark, subject: anytype) !void {
    if (!mem.containsAtLeast(u8, subject.filename, 1, options.filter)) return;
    try bench.add("(NOAA) " ++ subject.filename, CompositorBenchmark(subject).f, .{});
}

fn addPathBenchmark(bench: *zbench.Benchmark, subject: anytype) !void {
    if (!mem.containsAtLeast(u8, subject.filename, 1, options.filter)) return;
    try bench.add("(NOAA) " ++ subject.filename, PathBenchmark(subject, .none).f, .{});
    try bench.add("(SSAA) " ++ subject.filename, PathBenchmark(subject, .supersample_4x).f, .{});
    try bench.add("(MSAA) " ++ subject.filename, PathBenchmark(subject, .multisample_4x).f, .{});
}

fn CompositorBenchmark(
    subject: anytype,
) type {
    return struct {
        fn f(alloc: mem.Allocator) void {
            var sfc = subject.render(alloc) catch |err| {
                debug.print("Error: {}\n", .{err});
                @panic("error running benchmark");
            };
            sfc.deinit(alloc);
        }
    };
}

fn PathBenchmark(
    subject: anytype,
    aa_mode: z2d.options.AntiAliasMode,
) type {
    return struct {
        fn f(alloc: mem.Allocator) void {
            var sfc = subject.render(alloc, aa_mode) catch |err| {
                debug.print("Error: {}\n", .{err});
                @panic("error running benchmark");
            };
            sfc.deinit(alloc);
        }
    };
}
