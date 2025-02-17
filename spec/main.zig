// SPDX-License-Identifier: 0BSD
//   Copyright © 2024 Chris Marchesi

const debug = @import("std").debug;
const fs = @import("std").fs;
const fmt = @import("std").fmt;
const heap = @import("std").heap;
const mem = @import("std").mem;
const sha256 = @import("std").crypto.hash.sha2.Sha256;
const testing = @import("std").testing;

const z2d = @import("z2d");
const tracy_enable = @import("spec_options").tracy_enable;
const tracy = if (tracy_enable) @import("tracy") else null;

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

//////////////////////////////////////////////////////////////////////////////

pub fn main() !void {
    var gpa = heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();

    try compositorExportRun(alloc, _001_smile_rgb);
    try compositorExportRun(alloc, _002_smile_rgba);
    try pathExportRun(alloc, _003_fill_triangle);
    try pathExportRun(alloc, _004_fill_square);
    try pathExportRun(alloc, _005_fill_trapezoid);
    try pathExportRun(alloc, _006_fill_star_even_odd);
    try pathExportRun(alloc, _007_fill_bezier);
    try pathExportRun(alloc, _008_stroke_triangle);
    try pathExportRun(alloc, _009_stroke_square);
    try pathExportRun(alloc, _010_stroke_trapezoid);
    try pathExportRun(alloc, _011_stroke_star);
    try pathExportRun(alloc, _012_stroke_bezier);
    try pathExportRun(alloc, _013_fill_combined);
    try pathExportRun(alloc, _014_stroke_lines);
    try pathExportRun(alloc, _015_stroke_miter);
    try pathExportRun(alloc, _016_fill_star_non_zero);
    try pathExportRun(alloc, _017_stroke_star_round);
    try pathExportRun(alloc, _018_stroke_square_spiral_round);
    try pathExportRun(alloc, _019_stroke_bevel_miterlimit);
    try pathExportRun(alloc, _020_stroke_lines_round_caps);
    try pathExportRun(alloc, _021_stroke_lines_square_caps);
    try pathExportRun(alloc, _022_stroke_lines_butt_caps);
    try compositorExportRun(alloc, _023_smile_alpha_mask);
    try pathExportRun(alloc, _024_fill_triangle_direct_cross_format);
    try pathExportRun(alloc, _025_fill_diamond_clipped);
    try pathExportRun(alloc, _026_fill_triangle_full);
    try pathExportRun(alloc, _027_stroke_bezier_tolerance);
    try pathExportRun(alloc, _028_fill_bezier_tolerance);
    try pathExportRun(alloc, _029_stroke_lines_round_caps_tolerance);
    try pathExportRun(alloc, _030_stroke_star_round_tolerance);
    try pathExportRun(alloc, _031_fill_quad_bezier);
    try pathExportRun(alloc, _032_fill_arc);
    try pathExportRun(alloc, _033_fill_zig_mark);
    try pathExportRun(alloc, _034_stroke_cross);
    try pathExportRun(alloc, _035_arc_command);
    try pathExportRun(alloc, _036_stroke_colinear);
    try pathExportRun(alloc, _037_stroke_join_overlap);
    try pathExportRun(alloc, _038_stroke_zero_length);
    try pathExportRun(alloc, _039_stroke_paint_extent_dontclip);
    try pathExportRun(alloc, _040_stroke_corner_symmetrical);
    try pathExportRun(alloc, _041_stroke_noop_lineto);
    try pathExportRun(alloc, _042_arc_ellipses);
    try pathExportRun(alloc, _043_rect_transforms);
    try pathExportRun(alloc, _044_line_transforms);
    try pathExportRun(alloc, _045_round_join_transforms);
    try pathExportRun(alloc, _046_fill_triangle_alpha);
    try pathExportRun(alloc, _047_fill_triangle_alpha_gray);
    try pathExportRun(alloc, _048_fill_triangle_static);
    try pathExportRun(alloc, _049_fill_triangle_alpha4_gray);
    try pathExportRun(alloc, _050_fill_triangle_alpha2_gray);
    try pathExportRun(alloc, _051_fill_triangle_alpha1_gray);
    try pathExportRun(alloc, _052_fill_triangle_alpha4_gray_scaledown);
    try pathExportRun(alloc, _053_fill_triangle_alpha8_gray_scaleup);
    try pathExportRun(alloc, _054_stroke_lines_dashed);
    try pathExportRun(alloc, _055_stroke_miter_dashed);
    try pathExportRun(alloc, _056_stroke_star_dashed);
    try pathExportRun(alloc, _057_stroke_bezier_dashed);
    try pathExportRun(alloc, _058_stroke_misc_dashes);
    try pathExportRun(alloc, _059_stroke_star_gradient);
    try pathExportRun(alloc, _060_ghostty_logo);
    try compositorExportRun(alloc, _061_linear_gradient);
    try compositorExportRun(alloc, _062_hsl_gradient);
}

//////////////////////////////////////////////////////////////////////////////

test "001_smile_rgb" {
    try compositorTestRun(testing.allocator, _001_smile_rgb);
}

test "002_smile_rgba" {
    try compositorTestRun(testing.allocator, _002_smile_rgba);
}

test "003_fill_triangle" {
    try pathTestRun(testing.allocator, _003_fill_triangle);
}

test "004_fill_square" {
    try pathTestRun(testing.allocator, _004_fill_square);
}

test "005_fill_trapezoid" {
    try pathTestRun(testing.allocator, _005_fill_trapezoid);
}

test "006_fill_star_even_odd" {
    try pathTestRun(testing.allocator, _006_fill_star_even_odd);
}

test "007_fill_bezier" {
    try pathTestRun(testing.allocator, _007_fill_bezier);
}

test "008_stroke_triangle" {
    try pathTestRun(testing.allocator, _008_stroke_triangle);
}

test "009_stroke_square" {
    try pathTestRun(testing.allocator, _009_stroke_square);
}

test "010_stroke_trapezoid" {
    try pathTestRun(testing.allocator, _010_stroke_trapezoid);
}

test "011_stroke_star" {
    try pathTestRun(testing.allocator, _011_stroke_star);
}

test "012_stroke_bezier" {
    try pathTestRun(testing.allocator, _012_stroke_bezier);
}

test "013_fill_combined" {
    try pathTestRun(testing.allocator, _013_fill_combined);
}

test "014_stroke_lines" {
    try pathTestRun(testing.allocator, _014_stroke_lines);
}

test "015_stroke_miter" {
    try pathTestRun(testing.allocator, _015_stroke_miter);
}

test "016_fill_star_non_zero" {
    try pathTestRun(testing.allocator, _016_fill_star_non_zero);
}

test "017_stroke_star_round" {
    try pathTestRun(testing.allocator, _017_stroke_star_round);
}

test "018_stroke_square_spiral_round" {
    try pathTestRun(testing.allocator, _018_stroke_square_spiral_round);
}

test "019_stroke_bevel_miterlimit" {
    try pathTestRun(testing.allocator, _019_stroke_bevel_miterlimit);
}

test "020_stroke_lines_round_caps" {
    try pathTestRun(testing.allocator, _020_stroke_lines_round_caps);
}

test "021_stroke_lines_square_caps" {
    try pathTestRun(testing.allocator, _021_stroke_lines_square_caps);
}

test "022_stroke_lines_butt_caps" {
    try pathTestRun(testing.allocator, _022_stroke_lines_butt_caps);
}

test "023_smile_alpha_mask" {
    try compositorTestRun(testing.allocator, _023_smile_alpha_mask);
}

test "024_fill_triangle_direct_cross_format" {
    try pathTestRun(testing.allocator, _024_fill_triangle_direct_cross_format);
}

test "025_fill_diamond_clipped" {
    try pathTestRun(testing.allocator, _025_fill_diamond_clipped);
}

test "026_fill_triangle_full" {
    try pathTestRun(testing.allocator, _026_fill_triangle_full);
}

test "027_stroke_bezier_tolerance" {
    try pathTestRun(testing.allocator, _027_stroke_bezier_tolerance);
}

test "028_fill_bezier_tolerance" {
    try pathTestRun(testing.allocator, _028_fill_bezier_tolerance);
}

test "029_stroke_lines_round_caps_tolerance" {
    try pathTestRun(testing.allocator, _029_stroke_lines_round_caps_tolerance);
}

test "030_stroke_star_round_tolerance" {
    try pathTestRun(testing.allocator, _030_stroke_star_round_tolerance);
}

test "031_fill_quad_bezier" {
    try pathTestRun(testing.allocator, _031_fill_quad_bezier);
}

test "032_fill_arc" {
    try pathTestRun(testing.allocator, _032_fill_arc);
}

test "033_fill_zig_mark" {
    try pathTestRun(testing.allocator, _033_fill_zig_mark);
}

test "034_stroke_cross" {
    try pathTestRun(testing.allocator, _034_stroke_cross);
}

test "035_arc_command" {
    try pathTestRun(testing.allocator, _035_arc_command);
}

test "036_stroke_colinear" {
    try pathTestRun(testing.allocator, _036_stroke_colinear);
}

test "037_stroke_join_overlap" {
    try pathTestRun(testing.allocator, _037_stroke_join_overlap);
}

test "038_stroke_zero_length" {
    try pathTestRun(testing.allocator, _038_stroke_zero_length);
}

test "039_stroke_paint_extent_dontclip" {
    try pathTestRun(testing.allocator, _039_stroke_paint_extent_dontclip);
}

test "040_stroke_corner_symmetrical" {
    try pathTestRun(testing.allocator, _040_stroke_corner_symmetrical);
}

test "041_stroke_noop_lineto" {
    try pathTestRun(testing.allocator, _041_stroke_noop_lineto);
}

test "042_arc_ellipses" {
    try pathTestRun(testing.allocator, _042_arc_ellipses);
}

test "043_rect_transforms" {
    try pathTestRun(testing.allocator, _043_rect_transforms);
}

test "044_line_transforms" {
    try pathTestRun(testing.allocator, _044_line_transforms);
}

test "045_round_join_transforms" {
    try pathTestRun(testing.allocator, _045_round_join_transforms);
}

test "046_fill_triangle_alpha" {
    try pathTestRun(testing.allocator, _046_fill_triangle_alpha);
}

test "047_fill_triangle_alpha_gray" {
    try pathTestRun(testing.allocator, _047_fill_triangle_alpha_gray);
}

test "048_fill_triangle_static" {
    try pathTestRun(testing.allocator, _048_fill_triangle_static);
}

test "049_fill_triangle_alpha4_gray" {
    try pathTestRun(testing.allocator, _049_fill_triangle_alpha4_gray);
}

test "050_fill_triangle_alpha2_gray" {
    try pathTestRun(testing.allocator, _050_fill_triangle_alpha2_gray);
}

test "051_fill_triangle_alpha1_gray" {
    try pathTestRun(testing.allocator, _051_fill_triangle_alpha1_gray);
}

test "052_fill_triangle_alpha4_gray_scaledown" {
    try pathTestRun(testing.allocator, _052_fill_triangle_alpha4_gray_scaledown);
}

test "053_fill_triangle_alpha8_gray_scaleup" {
    try pathTestRun(testing.allocator, _053_fill_triangle_alpha8_gray_scaleup);
}

test "054_stroke_lines_dashed" {
    try pathTestRun(testing.allocator, _054_stroke_lines_dashed);
}

test "055_stroke_miter_dashed" {
    try pathTestRun(testing.allocator, _055_stroke_miter_dashed);
}

test "056_stroke_star_dashed" {
    try pathTestRun(testing.allocator, _056_stroke_star_dashed);
}

test "057_stroke_bezier_dashed" {
    try pathTestRun(testing.allocator, _057_stroke_bezier_dashed);
}

test "058_stroke_misc_dashes" {
    try pathTestRun(testing.allocator, _058_stroke_misc_dashes);
}

test "059_stroke_star_gradient" {
    try pathTestRun(testing.allocator, _059_stroke_star_gradient);
}

test "060_ghostty_logo" {
    try pathTestRun(testing.allocator, _060_ghostty_logo);
}

test "061_linear_gradient" {
    try compositorTestRun(testing.allocator, _061_linear_gradient);
}

test "062_hsl_gradient" {
    try compositorTestRun(testing.allocator, _062_hsl_gradient);
}

//////////////////////////////////////////////////////////////////////////////

fn compositorExportRun(alloc: mem.Allocator, subject: anytype) !void {
    const filename = try fmt.allocPrint(
        alloc,
        "{s}{s}",
        .{ subject.filename, ".png" },
    );
    defer alloc.free(filename);

    var surface = try subject.render(alloc);
    defer surface.deinit(alloc);

    try specExportPNG(alloc, surface, filename);
}

fn pathExportRun(alloc: mem.Allocator, subject: anytype) !void {
    const filename_pixelated = try fmt.allocPrint(
        alloc,
        "{s}{s}{s}",
        .{ subject.filename, "_pixelated", ".png" },
    );
    defer alloc.free(filename_pixelated);
    const filename_smooth = try fmt.allocPrint(
        alloc,
        "{s}{s}{s}",
        .{ subject.filename, "_smooth", ".png" },
    );
    defer alloc.free(filename_smooth);

    var surface_pixelated = try subject.render(alloc, .none);
    defer surface_pixelated.deinit(alloc);
    var surface_smooth = try subject.render(alloc, .default);
    defer surface_smooth.deinit(alloc);

    try specExportPNG(alloc, surface_pixelated, filename_pixelated);
    try specExportPNG(alloc, surface_smooth, filename_smooth);
}

fn specExportPNG(alloc: mem.Allocator, surface: z2d.Surface, filename: []const u8) !void {
    const target_path = try fs.path.join(alloc, &.{ "spec/files", filename });
    defer alloc.free(target_path);
    try z2d.png_exporter.writeToPNGFile(surface, target_path);
}

fn compositorTestRun(alloc: mem.Allocator, subject: anytype) !void {
    const filename = try fmt.allocPrint(
        alloc,
        "{s}{s}",
        .{ subject.filename, ".png" },
    );
    defer alloc.free(filename);
    var exported_file: testExportPNGDetails = undefined;

    if (tracy_enable) {
        var tracy_alloc_ = tracy.TracingAllocator.init(alloc);
        const tracy_alloc = tracy_alloc_.allocator();

        var surface = surface: {
            const zone = tracy.initZone(@src(), .{ .name = "compositorTestRun: render" });
            defer zone.deinit();
            break :surface try subject.render(tracy_alloc);
        };
        defer surface.deinit(tracy_alloc);

        exported_file = exported_file: {
            const zone = tracy.initZone(@src(), .{ .name = "compositorTestRun: export" });
            defer zone.deinit();
            break :exported_file try testExportPNG(tracy_alloc, surface, filename);
        };
    } else {
        var surface = try subject.render(alloc);
        defer surface.deinit(alloc);

        exported_file = try testExportPNG(alloc, surface, filename);
    }
    defer exported_file.cleanup();

    try compareFiles(testing.allocator, exported_file.target_path);
}

fn pathTestRun(alloc: mem.Allocator, subject: anytype) !void {
    const filename_pixelated = try fmt.allocPrint(
        alloc,
        "{s}{s}{s}",
        .{ subject.filename, "_pixelated", ".png" },
    );
    defer alloc.free(filename_pixelated);
    const filename_smooth = try fmt.allocPrint(
        alloc,
        "{s}{s}{s}",
        .{ subject.filename, "_smooth", ".png" },
    );
    defer alloc.free(filename_smooth);

    var exported_file_pixelated: testExportPNGDetails = undefined;
    var exported_file_smooth: testExportPNGDetails = undefined;

    if (tracy_enable) {
        var tracy_alloc_ = tracy.TracingAllocator.init(alloc);
        const tracy_alloc = tracy_alloc_.allocator();

        var surface_pixelated = surface_pixelated: {
            const zone = tracy.initZone(@src(), .{ .name = "pathTestRun: render (aa_mode = .none)" });
            defer zone.deinit();
            break :surface_pixelated try subject.render(tracy_alloc, .none);
        };
        defer surface_pixelated.deinit(tracy_alloc);
        var surface_smooth = surface_smooth: {
            const zone = tracy.initZone(@src(), .{ .name = "pathTestRun: render (aa_mode = .default)" });
            defer zone.deinit();
            break :surface_smooth try subject.render(tracy_alloc, .default);
        };
        defer surface_smooth.deinit(tracy_alloc);

        exported_file_pixelated = exported_file_pixelated: {
            const zone = tracy.initZone(@src(), .{ .name = "pathTestRun: export (aa_mode = .none)" });
            defer zone.deinit();
            break :exported_file_pixelated try testExportPNG(
                tracy_alloc,
                surface_pixelated,
                filename_pixelated,
            );
        };
        exported_file_smooth = exported_file_smooth: {
            const zone = tracy.initZone(@src(), .{ .name = "pathTestRun: export (aa_mode = .default)" });
            defer zone.deinit();
            break :exported_file_smooth try testExportPNG(
                tracy_alloc,
                surface_smooth,
                filename_smooth,
            );
        };
    } else {
        var surface_pixelated = try subject.render(alloc, .none);
        defer surface_pixelated.deinit(alloc);
        var surface_smooth = try subject.render(alloc, .default);
        defer surface_smooth.deinit(alloc);

        exported_file_pixelated = try testExportPNG(alloc, surface_pixelated, filename_pixelated);
        exported_file_smooth = try testExportPNG(alloc, surface_smooth, filename_smooth);
    }
    defer exported_file_pixelated.cleanup();
    defer exported_file_smooth.cleanup();

    try compareFiles(testing.allocator, exported_file_pixelated.target_path);
    try compareFiles(testing.allocator, exported_file_smooth.target_path);
}

const testExportPNGDetails = struct {
    tmp_dir: testing.TmpDir,
    target_path: []const u8,
    alloc: mem.Allocator,

    fn cleanup(self: *testExportPNGDetails) void {
        self.alloc.free(self.target_path);
        self.tmp_dir.cleanup();
    }
};

fn testExportPNG(alloc: mem.Allocator, surface: z2d.Surface, filename: []const u8) !testExportPNGDetails {
    var tmp_dir = testing.tmpDir(.{});
    errdefer tmp_dir.cleanup();
    const parent_path = try tmp_dir.dir.realpathAlloc(alloc, ".");
    defer alloc.free(parent_path);
    const target_path = try fs.path.join(alloc, &.{ parent_path, filename });
    errdefer alloc.free(target_path);

    try z2d.png_exporter.writeToPNGFile(surface, target_path);

    return .{
        .tmp_dir = tmp_dir,
        .target_path = target_path,
        .alloc = alloc,
    };
}

fn compareFiles(alloc: mem.Allocator, actual_filename: []const u8) !void {
    const max_file_size = 10240000; // 10MB

    // We expect the file with the same name to be in spec/files
    const base_file = fs.path.basename(actual_filename);
    const expected_filename = try fs.path.join(alloc, &.{ "spec/files", base_file });
    defer alloc.free(expected_filename);
    const expected_data = try fs.cwd().readFileAlloc(alloc, expected_filename, max_file_size);
    defer alloc.free(expected_data);
    var expected_hash: [sha256.digest_length]u8 = undefined;
    sha256.hash(expected_data, &expected_hash, .{});

    const actual_data = try fs.cwd().readFileAlloc(alloc, actual_filename, max_file_size);
    defer alloc.free(actual_data);
    var actual_hash: [sha256.digest_length]u8 = undefined;
    sha256.hash(actual_data, &actual_hash, .{});

    if (!mem.eql(u8, &expected_hash, &actual_hash)) {
        debug.print(
            "files differ: {s} ({x}) vs {s} ({x})\n",
            .{ expected_filename, expected_hash, actual_filename, actual_hash },
        );
        return error.SpecTestFileMismatch;
    }
}
