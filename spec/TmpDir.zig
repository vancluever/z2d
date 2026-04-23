//! An implementation of testing.TmpDir that works with non-testing code;
//! needed by 0.16 for testing scenarios that don't techincally run under "zig
//! test", e.g., building ground-truth test data, etc.
//!
//! Code taken from the Zig stdlib.
//!
//! NOTE: This code should still only generally be used for testing purposes as
//! it still co-locates everything in .zig-cache versus conforming to any
//! specific standard like POSIX, FHS, etc, not to mention more exotic setups
//! that do not match these standards like Windows.
const TmpDir = @This();

const std = @import("std");

dir: std.Io.Dir,
parent_dir: std.Io.Dir,
sub_path: [sub_path_len]u8,

const random_bytes_count = 12;
const sub_path_len = std.base64.url_safe.Encoder.calcSize(random_bytes_count);

pub fn cleanup(self: *TmpDir, io: std.Io) void {
    self.dir.close(io);
    self.parent_dir.deleteTree(io, &self.sub_path) catch {};
    self.parent_dir.close(io);
    self.* = undefined;
}

pub fn init(io: std.Io, opts: std.Io.Dir.OpenOptions) TmpDir {
    var random_bytes: [TmpDir.random_bytes_count]u8 = undefined;
    io.random(&random_bytes);
    var sub_path: [TmpDir.sub_path_len]u8 = undefined;
    _ = std.base64.url_safe.Encoder.encode(&sub_path, &random_bytes);

    const cwd = std.Io.Dir.cwd();
    var cache_dir = cwd.createDirPathOpen(io, ".zig-cache", .{}) catch
        @panic("unable to make tmp dir for testing: unable to make and open .zig-cache dir");
    defer cache_dir.close(io);
    const parent_dir = cache_dir.createDirPathOpen(io, "tmp", .{}) catch
        @panic("unable to make tmp dir for testing: unable to make and open .zig-cache/tmp dir");
    const dir = parent_dir.createDirPathOpen(io, &sub_path, .{ .open_options = opts }) catch
        @panic("unable to make tmp dir for testing: unable to make and open the tmp dir");

    return .{
        .dir = dir,
        .parent_dir = parent_dir,
        .sub_path = sub_path,
    };
}
