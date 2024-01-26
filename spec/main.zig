const debug = @import("std").debug;
const fs = @import("std").fs;
const heap = @import("std").heap;
const mem = @import("std").mem;
const sha256 = @import("std").crypto.hash.sha2.Sha256;
const testing = @import("std").testing;

const z2d = @import("z2d");

const _001_smile_rgb = @import("001_smile_rgb.zig");
const _002_smile_rgba = @import("002_smile_rgba.zig");

//////////////////////////////////////////////////////////////////////////////

pub fn main() !void {
    var gpa = heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();

    try gen_001_smile_rgb(alloc);
    try gen_002_smile_rgba(alloc);
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

//////////////////////////////////////////////////////////////////////////////

fn specExportPNG(alloc: mem.Allocator, surface: z2d.Surface, filename: []const u8) !void {
    const target_path = try fs.path.join(alloc, &.{ "spec/files", filename });
    errdefer alloc.free(target_path);
    try z2d.writeToPNGFile(alloc, surface, target_path);
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

    try z2d.writeToPNGFile(alloc, surface, target_path);

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
