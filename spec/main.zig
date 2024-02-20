const debug = @import("std").debug;
const fs = @import("std").fs;
const heap = @import("std").heap;
const mem = @import("std").mem;
const sha256 = @import("std").crypto.hash.sha2.Sha256;
const testing = @import("std").testing;

const z2d = @import("z2d");

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
// const _012_stroke_bezier = @import("012_stroke_bezier.zig");
const _013_fill_combined = @import("013_fill_combined.zig");
const _014_stroke_lines = @import("014_stroke_lines.zig");
const _015_stroke_miter = @import("015_stroke_miter.zig");

//////////////////////////////////////////////////////////////////////////////

pub fn main() !void {
    var gpa = heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();

    try gen_001_smile_rgb(alloc);
    try gen_002_smile_rgba(alloc);
    try gen_003_fill_triangle(alloc);
    try gen_004_fill_square(alloc);
    try gen_005_fill_trapezoid(alloc);
    try gen_006_fill_star_even_odd(alloc);
    try gen_007_fill_bezier(alloc);
    try gen_008_stroke_triangle(alloc);
    try gen_009_stroke_square(alloc);
    try gen_010_stroke_trapezoid(alloc);
    try gen_011_stroke_star(alloc);
    // try gen_012_stroke_bezier(alloc);
    try gen_013_fill_combined(alloc);
    try gen_014_stroke_lines(alloc);
    try gen_015_stroke_miter(alloc);
}

fn gen_001_smile_rgb(alloc: mem.Allocator) !void {
    var surface = try _001_smile_rgb.render(alloc);
    defer surface.deinit();
    try specExportPNG(alloc, surface, _001_smile_rgb.filename);
}

fn gen_002_smile_rgba(alloc: mem.Allocator) !void {
    var surface = try _002_smile_rgba.render(alloc);
    defer surface.deinit();
    try specExportPNG(alloc, surface, _002_smile_rgba.filename);
}

fn gen_003_fill_triangle(alloc: mem.Allocator) !void {
    var surface = try _003_fill_triangle.render(alloc);
    defer surface.deinit();
    try specExportPNG(alloc, surface, _003_fill_triangle.filename);
}

fn gen_004_fill_square(alloc: mem.Allocator) !void {
    var surface = try _004_fill_square.render(alloc);
    defer surface.deinit();
    try specExportPNG(alloc, surface, _004_fill_square.filename);
}

fn gen_005_fill_trapezoid(alloc: mem.Allocator) !void {
    var surface = try _005_fill_trapezoid.render(alloc);
    defer surface.deinit();
    try specExportPNG(alloc, surface, _005_fill_trapezoid.filename);
}

fn gen_006_fill_star_even_odd(alloc: mem.Allocator) !void {
    var surface = try _006_fill_star_even_odd.render(alloc);
    defer surface.deinit();
    try specExportPNG(alloc, surface, _006_fill_star_even_odd.filename);
}

fn gen_007_fill_bezier(alloc: mem.Allocator) !void {
    var surface = try _007_fill_bezier.render(alloc);
    defer surface.deinit();
    try specExportPNG(alloc, surface, _007_fill_bezier.filename);
}

fn gen_008_stroke_triangle(alloc: mem.Allocator) !void {
    var surface = try _008_stroke_triangle.render(alloc);
    defer surface.deinit();
    try specExportPNG(alloc, surface, _008_stroke_triangle.filename);
}

fn gen_009_stroke_square(alloc: mem.Allocator) !void {
    var surface = try _009_stroke_square.render(alloc);
    defer surface.deinit();
    try specExportPNG(alloc, surface, _009_stroke_square.filename);
}

fn gen_010_stroke_trapezoid(alloc: mem.Allocator) !void {
    var surface = try _010_stroke_trapezoid.render(alloc);
    defer surface.deinit();
    try specExportPNG(alloc, surface, _010_stroke_trapezoid.filename);
}

fn gen_011_stroke_star(alloc: mem.Allocator) !void {
    var surface = try _011_stroke_star.render(alloc);
    defer surface.deinit();
    try specExportPNG(alloc, surface, _011_stroke_star.filename);
}

// fn gen_012_stroke_bezier(alloc: mem.Allocator) !void {
//     var surface = try _012_stroke_bezier.render(alloc);
//     defer surface.deinit();
//     try specExportPNG(alloc, surface, _012_stroke_bezier.filename);
// }

fn gen_013_fill_combined(alloc: mem.Allocator) !void {
    var surface = try _013_fill_combined.render(alloc);
    defer surface.deinit();
    try specExportPNG(alloc, surface, _013_fill_combined.filename);
}

fn gen_014_stroke_lines(alloc: mem.Allocator) !void {
    var surface = try _014_stroke_lines.render(alloc);
    defer surface.deinit();
    try specExportPNG(alloc, surface, _014_stroke_lines.filename);
}

fn gen_015_stroke_miter(alloc: mem.Allocator) !void {
    var surface = try _015_stroke_miter.render(alloc);
    defer surface.deinit();
    try specExportPNG(alloc, surface, _015_stroke_miter.filename);
}

//////////////////////////////////////////////////////////////////////////////

test "001_smile_rgb" {
    var surface = try _001_smile_rgb.render(testing.allocator);
    defer surface.deinit();

    var exported_file = try testExportPNG(testing.allocator, surface, _001_smile_rgb.filename);
    defer exported_file.cleanup();

    try compareFiles(testing.allocator, exported_file.target_path);
}

test "002_smile_rgba" {
    var surface = try _002_smile_rgba.render(testing.allocator);
    defer surface.deinit();

    var exported_file = try testExportPNG(testing.allocator, surface, _002_smile_rgba.filename);
    defer exported_file.cleanup();

    try compareFiles(testing.allocator, exported_file.target_path);
}

test "003_fill_triangle" {
    var surface = try _003_fill_triangle.render(testing.allocator);
    defer surface.deinit();

    var exported_file = try testExportPNG(testing.allocator, surface, _003_fill_triangle.filename);
    defer exported_file.cleanup();

    try compareFiles(testing.allocator, exported_file.target_path);
}

test "004_fill_square" {
    var surface = try _004_fill_square.render(testing.allocator);
    defer surface.deinit();

    var exported_file = try testExportPNG(testing.allocator, surface, _004_fill_square.filename);
    defer exported_file.cleanup();

    try compareFiles(testing.allocator, exported_file.target_path);
}

test "005_fill_trapezoid" {
    var surface = try _005_fill_trapezoid.render(testing.allocator);
    defer surface.deinit();

    var exported_file = try testExportPNG(testing.allocator, surface, _005_fill_trapezoid.filename);
    defer exported_file.cleanup();

    try compareFiles(testing.allocator, exported_file.target_path);
}

test "006_fill_star_even_odd" {
    var surface = try _006_fill_star_even_odd.render(testing.allocator);
    defer surface.deinit();

    var exported_file = try testExportPNG(testing.allocator, surface, _006_fill_star_even_odd.filename);
    defer exported_file.cleanup();

    try compareFiles(testing.allocator, exported_file.target_path);
}

test "007_fill_bezier" {
    var surface = try _007_fill_bezier.render(testing.allocator);
    defer surface.deinit();

    var exported_file = try testExportPNG(testing.allocator, surface, _007_fill_bezier.filename);
    defer exported_file.cleanup();

    try compareFiles(testing.allocator, exported_file.target_path);
}

test "008_stroke_triangle" {
    var surface = try _008_stroke_triangle.render(testing.allocator);
    defer surface.deinit();

    var exported_file = try testExportPNG(testing.allocator, surface, _008_stroke_triangle.filename);
    defer exported_file.cleanup();

    try compareFiles(testing.allocator, exported_file.target_path);
}

test "009_stroke_square" {
    var surface = try _009_stroke_square.render(testing.allocator);
    defer surface.deinit();

    var exported_file = try testExportPNG(testing.allocator, surface, _009_stroke_square.filename);
    defer exported_file.cleanup();

    try compareFiles(testing.allocator, exported_file.target_path);
}

test "010_stroke_trapezoid" {
    var surface = try _010_stroke_trapezoid.render(testing.allocator);
    defer surface.deinit();

    var exported_file = try testExportPNG(testing.allocator, surface, _010_stroke_trapezoid.filename);
    defer exported_file.cleanup();

    try compareFiles(testing.allocator, exported_file.target_path);
}

test "011_stroke_star" {
    var surface = try _011_stroke_star.render(testing.allocator);
    defer surface.deinit();

    var exported_file = try testExportPNG(testing.allocator, surface, _011_stroke_star.filename);
    defer exported_file.cleanup();

    try compareFiles(testing.allocator, exported_file.target_path);
}

// test "012_stroke_bezier" {
//     var surface = try _012_stroke_bezier.render(testing.allocator);
//     defer surface.deinit();
//
//     var exported_file = try testExportPNG(testing.allocator, surface, _012_stroke_bezier.filename);
//     defer exported_file.cleanup();
//
//     try compareFiles(testing.allocator, exported_file.target_path);
// }

test "013_fill_combined" {
    var surface = try _013_fill_combined.render(testing.allocator);
    defer surface.deinit();

    var exported_file = try testExportPNG(testing.allocator, surface, _013_fill_combined.filename);
    defer exported_file.cleanup();

    try compareFiles(testing.allocator, exported_file.target_path);
}

test "014_stroke_lines" {
    var surface = try _014_stroke_lines.render(testing.allocator);
    defer surface.deinit();

    var exported_file = try testExportPNG(testing.allocator, surface, _014_stroke_lines.filename);
    defer exported_file.cleanup();

    try compareFiles(testing.allocator, exported_file.target_path);
}

test "015_stroke_miter" {
    var surface = try _015_stroke_miter.render(testing.allocator);
    defer surface.deinit();

    var exported_file = try testExportPNG(testing.allocator, surface, _015_stroke_miter.filename);
    defer exported_file.cleanup();

    try compareFiles(testing.allocator, exported_file.target_path);
}

//////////////////////////////////////////////////////////////////////////////

fn specExportPNG(alloc: mem.Allocator, surface: z2d.Surface, filename: []const u8) !void {
    const target_path = try fs.path.join(alloc, &.{ "spec/files", filename });
    errdefer alloc.free(target_path);
    try z2d.writeToPNGFile(surface, target_path);
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
    const parent_path = try tmp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer alloc.free(parent_path);
    const target_path = try fs.path.join(alloc, &.{ parent_path, filename });
    errdefer alloc.free(target_path);

    try z2d.writeToPNGFile(surface, target_path);

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
