const std = @import("std");
const sha256 = std.crypto.hash.sha2.Sha256;

const max_file_size = 10240000; // 10MB

pub fn compareFiles(alloc: std.mem.Allocator, expected: []const u8, actual: []const u8) !void {
    const expected_data = try std.fs.cwd().readFileAlloc(alloc, expected, max_file_size);
    defer alloc.free(expected_data);
    var expected_hash: [sha256.digest_length]u8 = undefined;
    sha256.hash(expected_data, &expected_hash, .{});

    const actual_data = try std.fs.cwd().readFileAlloc(alloc, actual, max_file_size);
    defer alloc.free(actual_data);
    var actual_hash: [sha256.digest_length]u8 = undefined;
    sha256.hash(actual_data, &actual_hash, .{});

    if (!std.mem.eql(u8, &expected_hash, &actual_hash)) {
        std.debug.print(
            "files differ: {s} ({x}) vs {s} ({x})\n",
            .{ expected, expected_hash, actual, actual_hash },
        );
        return error.SpecTestFileMismatch;
    }
}
