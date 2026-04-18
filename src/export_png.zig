// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024-2025 Chris Marchesi

//! Rudimentary PNG export functionality.

const builtin = @import("std").builtin;
const crc32 = @import("std").hash.Crc32;
const debug = @import("std").debug;
const fmt = @import("std").fmt;
const fs = @import("std").fs;
const Io = @import("std").Io;
const math = @import("std").math;
const mem = @import("std").mem;
const sha256 = @import("std").crypto.hash.sha2.Sha256;
const testing = @import("std").testing;
const flate = @import("std").compress.flate;

const color = @import("color.zig");
const color_vector = @import("internal/color_vector.zig");
const pixel = @import("pixel.zig");
const pixel_vector = @import("internal/pixel_vector.zig");
const surface = @import("surface.zig");

const vector_length = @import("z2d.zig").vector_length;

const native_endian = @import("builtin").cpu.arch.endian();

pub const BytesWrittenMismatchError = error{
    /// Error during streaming graphical data.
    BytesWrittenMismatch,
};

pub const WriteToPNGFileOptions = struct {
    /// The RGB/color profile to use for exporting.
    ///
    /// When set, the gAMA header is set appropriately for the gamma transfer
    /// number, and the image data is re-encoded with the gamma if necessary.
    ///
    /// The default is to not add the gAMA header or encode the gamma.
    color_profile: ?color.RGBProfile = null,
};

pub const WriteToPNGFileError = WritePNGMagicError ||
    WritePNGIHDRError ||
    WritePNGgAMAError ||
    WritePNGIDATStreamError ||
    WritePNGIENDError ||
    Io.File.OpenError;

/// Exports the surface to a PNG file supplied by filename.
///
/// This is currently a very rudimentary export with default zlib compression
/// and no pixel filtering.
///
/// Additional options to control the export can be supplied in opts.
pub fn writeToPNGFile(
    io: Io,
    sfc: surface.Surface,
    filename: []const u8,
    opts: WriteToPNGFileOptions,
) WriteToPNGFileError!void {
    // Assert the height and width of the surface, we always enforce a minimum
    // 1x1 surface now.
    if (sfc.getWidth() < 1 or sfc.getHeight() < 1) {
        @panic("invalid surface width or height (w|h < 1). this is a bug, please report it");
    }

    // Open and create the file.
    const file = try Io.Dir.cwd().createFile(io, filename, .{});
    defer file.close(io);

    // NOTE: No buffer for now for writing (seems okay). We have a 16K buffer
    // for our zlib stream, which is the only real area of the PNG export that
    // will see significant pressure. Otherwise, it's all chunks that will only
    // be written once. We can revisit this if need be.
    var writer = file.writer(io, &.{});

    // Write out magic header, and various chunks.
    try writePNGMagic(&writer.interface);
    try writePNGIHDR(&writer.interface, sfc);
    if (opts.color_profile) |profile| try writePNGgAMA(&writer.interface, profile);
    try writePNGIDATStream(&writer.interface, sfc, opts.color_profile);
    try writePNGIEND(&writer.interface);
}

const WritePNGMagicError = BytesWrittenMismatchError || Io.Writer.Error;

/// Writes the magic header for the PNG file.
fn writePNGMagic(writer: *Io.Writer) WritePNGMagicError!void {
    const header = "\x89PNG\x0D\x0A\x1A\x0A";
    if (try writer.write(header) != header.len) return error.BytesWrittenMismatch;
}

const WritePNGIHDRError = WritePNGWriteChunkError;

/// Writes the IHDR chunk for the PNG file.
fn writePNGIHDR(writer: *Io.Writer, sfc: surface.Surface) WritePNGIHDRError!void {
    var width = [_]u8{0} ** 4;
    var height = [_]u8{0} ** 4;

    mem.writeInt(u32, &width, @max(0, sfc.getWidth()), .big);
    mem.writeInt(u32, &height, @max(0, sfc.getHeight()), .big);
    const depth: u8 = switch (sfc.getFormat()) {
        .argb, .xrgb, .rgb, .rgba, .alpha8 => 8,
        .alpha4 => 4,
        .alpha2 => 2,
        .alpha1 => 1,
    };
    const color_type: u8 = switch (sfc.getFormat()) {
        .argb, .rgba => 6,
        .xrgb, .rgb => 2,
        .alpha8, .alpha4, .alpha2, .alpha1 => 0,
    };
    const compression: u8 = 0;
    const filter: u8 = 0;
    const interlace: u8 = 0;

    try writePNGWriteChunk(
        writer,
        "IHDR".*,
        &(width ++
            height ++
            [_]u8{depth} ++
            [_]u8{color_type} ++
            [_]u8{compression} ++
            [_]u8{filter} ++
            [_]u8{interlace}),
    );
}

const WritePNGgAMAError = WritePNGWriteChunkError;

fn writePNGgAMA(writer: *Io.Writer, profile: color.RGBProfile) WritePNGgAMAError!void {
    const gamma: u32 = @intFromFloat((switch (profile) {
        .linear => 1 / color.LinearRGB.gamma,
        .srgb => 1 / color.SRGB.gamma,
    }) * 100000);
    var gamma_bytes = [_]u8{0} ** 4;
    mem.writeInt(u32, &gamma_bytes, gamma, .big);
    try writePNGWriteChunk(
        writer,
        "gAMA".*,
        &gamma_bytes,
    );
}

const WritePNGIDATStreamError = Io.Writer.Error;

/// Write the IDAT stream (pixel data) for the PNG file.
///
/// This is currently a very rudimentary algorithm - default zlib
/// compression and no pixel filtering.
fn writePNGIDATStream(
    writer: *Io.Writer,
    sfc: surface.Surface,
    profile: ?color.RGBProfile,
) WritePNGIDATStreamError!void {
    const sfc_width: i32 = sfc.getWidth();
    const sfc_height: i32 = sfc.getHeight();

    const IDATStream = struct {
        const buffer_size = 16384;

        output_file_writer: *Io.Writer,
        idat_stream_writer: Io.Writer,

        fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
            switch (data.len) {
                0 => @panic("at least one data entry must be provided"),
                1 => if (splat == 0) return 0,
                else => {},
            }
            const stream_writer: *@This() = @fieldParentPtr("idat_stream_writer", w);
            writePNGIDATSingle(stream_writer.output_file_writer, w.buffer[0..w.end]) catch return error.WriteFailed;
            const len: usize = @min(data[0].len, buffer_size);
            @memcpy(w.buffer[0..len], data[0][0..len]);
            w.end = len;
            return len;
        }
    };

    var idat_buffer = [_]u8{0} ** IDATStream.buffer_size;
    var zlib_buffer = [_]u8{0} ** flate.max_window_len;
    var idat_stream: IDATStream = .{
        .output_file_writer = writer,
        .idat_stream_writer = .{
            .buffer = &idat_buffer,
            .vtable = &.{
                .drain = IDATStream.drain,
            },
        },
    };
    var zlib_stream: flate.Compress = try .init(
        &idat_stream.idat_stream_writer,
        &zlib_buffer,
        .zlib,
        flate.Compress.Options.default,
    );

    // To encode, we read from our buffer, pixel-by-pixel, and convert
    // to a writable format (big-endian, no padding). We also need to
    // add scanline filtering headers were appropriate.
    //
    // Iterate through each line to encode as scanlines.
    for (0..@max(0, sfc_height)) |y_u| {
        const y: i32 = @intCast(y_u);
        // Initialize a buffer for pixels. TODO: This will need to
        // increase/change when/if we add additional pixel filtering
        // algorithms.
        //
        // Buffer is 4 * vector_length + 1 bytes to accommodate both scanline
        // header and current maximum bpp (which is a u32).
        var pixel_buffer = [_]u8{0} ** (4 * vector_length + 1);
        var nbytes: usize = 1; // Adds scanline header (0x00 - no filtering)

        const stride = sfc.getStride(0, y, @max(0, sfc_width));
        // Step on our vector length, make sure we have a min loop length of 1
        // to ensure we catch the remainder of a line when it's less than the
        // vector length.
        for (0..@max(0, sfc_width) / vector_length + 1) |x_step| {
            const x: usize = x_step * vector_length;
            nbytes += written: {
                const stride_len: usize = stride_len: {
                    const remaining: usize = @max(0, sfc_width) - x;
                    break :stride_len if (remaining < vector_length)
                        remaining
                    else
                        vector_length;
                };

                if (stride_len == 0) {
                    // Early exit if for some reason we don't have data
                    break :written 0;
                }

                switch (stride) {
                    inline .xrgb, .rgb => |s| {
                        var stride_vec = [_]u32{0} ** vector_length;
                        @memcpy(stride_vec[0..stride_len], @as([]u32, @ptrCast(s[x .. x + stride_len])));
                        stride_vec = encodeRGBAVec(
                            stride_vec,
                            profile,
                            @typeInfo(@TypeOf(s)).pointer.child == pixel.XRGB,
                            false,
                        );
                        const stride_bytes = u32PixelToBytesLittleVec(stride_vec);
                        for (0..stride_len) |i| {
                            const j = i * 3;
                            const k = i * 4;
                            @memcpy(pixel_buffer[nbytes + j .. nbytes + j + 3], stride_bytes[k .. k + 3]);
                        }
                        break :written stride_len * 3;
                    },
                    inline .argb, .rgba => |s| {
                        var stride_vec = [_]u32{0} ** vector_length;
                        @memcpy(stride_vec[0..stride_len], @as([]u32, @ptrCast(s[x .. x + stride_len])));
                        stride_vec = encodeRGBAVec(
                            stride_vec,
                            profile,
                            @typeInfo(@TypeOf(s)).pointer.child == pixel.ARGB,
                            true,
                        );
                        const stride_bytes = u32PixelToBytesLittleVec(stride_vec);
                        for (0..stride_len) |i| {
                            const j = i * 4;
                            @memcpy(pixel_buffer[nbytes + j .. nbytes + j + 4], stride_bytes[j .. j + 4]);
                        }
                        break :written stride_len * 4;
                    },
                    .alpha8 => |s| {
                        @memcpy(
                            pixel_buffer[nbytes .. nbytes + stride_len],
                            @as([]u8, @ptrCast(s[x .. x + stride_len])),
                        );
                        break :written stride_len;
                    },
                    inline .alpha4, .alpha2, .alpha1 => |s| {
                        // We pack manually here as
                        // readPackedInt/writePackedInt semantics aren't
                        // necessarily what we want, due to how byte order
                        // works in PNG.
                        for (nbytes..pixel_buffer.len) |i| pixel_buffer[i] = 0; // zero buffer first
                        for (0..stride_len) |i| {
                            const px_int = @as(
                                u8,
                                @TypeOf(s).T.getFromPacked(s.buf, s.px_offset + x + i).a,
                            );
                            const n_bits = @bitSizeOf(@TypeOf(s).T.IntType);
                            const scale = 8 / n_bits;
                            const buf_idx = nbytes + i / scale;
                            const sh_bits = 8 - n_bits - i % scale * n_bits;
                            pixel_buffer[buf_idx] = pixel_buffer[buf_idx] | px_int << @intCast(sh_bits);
                        }
                        break :written (stride_len * @bitSizeOf(@TypeOf(s).T.IntType) + 7) / 8;
                    },
                }
            };

            // Write out the encoded pixels to the stream
            try zlib_stream.writer.writeAll(pixel_buffer[0..nbytes]);

            // Reset nbytes for the next run.
            nbytes = 0;
        }
    }

    // Close off and write the remaining bytes. This should always succeed.
    try zlib_stream.finish();
    try idat_stream.idat_stream_writer.flush();
}

/// Returns a cast of u32 vectors to u8 (little endian).
fn u32PixelToBytesLittleVec(value: [vector_length]u32) [vector_length * 4]u8 {
    return @bitCast(if (native_endian == .little) value else @byteSwap(value));
}

/// Demultiplies and encodes a vector-length RGBA array using a supplied color
/// profile.
fn encodeRGBAVec(
    value: [vector_length]u32,
    profile: ?color.RGBProfile,
    comptime in_argb: bool,
    comptime use_alpha: bool,
) [vector_length]u32 {
    var rgba_vector: pixel_vector.RGBA16 = undefined;
    inline for (0..vector_length) |i| {
        const rgba_scalar: if (in_argb) pixel.ARGB else pixel.RGBA = @bitCast(value[i]);
        rgba_vector.r[i] = rgba_scalar.r;
        rgba_vector.g[i] = rgba_scalar.g;
        rgba_vector.b[i] = rgba_scalar.b;
        rgba_vector.a[i] = if (use_alpha) rgba_scalar.a else 255;
    }

    // Our default space is linear. Even in our floating-point color spaces, we
    // de-multiply first in integer space when using the higher-level decoding
    // methods, so it's OK to always de-multiply in integer space here.
    if (use_alpha) rgba_vector = rgba_vector.demultiply();

    // We only have sRGB currently, outside of linear space, so just check to
    // see if we need to decode and apply the gamma for that. More formats may
    // come later.
    if (profile orelse .linear == .srgb) {
        var decoded = color_vector.SRGB.decodeRGBAVecRaw(.{
            .r = @intCast(rgba_vector.r),
            .g = @intCast(rgba_vector.g),
            .b = @intCast(rgba_vector.b),
            .a = @intCast(rgba_vector.a),
        });
        decoded = color_vector.SRGB.applyGammaVec(decoded);
        const encoded = color_vector.SRGB.encodeRGBAVecRaw(decoded);
        rgba_vector.r = encoded.r;
        rgba_vector.g = encoded.g;
        rgba_vector.b = encoded.b;
        rgba_vector.a = encoded.a;
    }

    // Encode the value to return
    var result: @Vector(vector_length, u32) = undefined;
    inline for (0..vector_length) |i| {
        const rgba_scalar: pixel.RGBA = .{
            .r = @intCast(rgba_vector.r[i]),
            .g = @intCast(rgba_vector.g[i]),
            .b = @intCast(rgba_vector.b[i]),
            .a = @intCast(rgba_vector.a[i]),
        };
        result[i] = @bitCast(rgba_scalar);
    }

    return result;
}

const WritePNGIDATSingleError = WritePNGWriteChunkError;

/// Writes a single IDAT chunk. The data should be part of the zlib
/// stream. See writePNG_IDAT_stream et al.
fn writePNGIDATSingle(writer: *Io.Writer, data: []const u8) WritePNGIDATSingleError!void {
    try writePNGWriteChunk(writer, "IDAT".*, data);
}

const WritePNGIENDError = WritePNGWriteChunkError;

/// Write the IEND chunk.
fn writePNGIEND(writer: *Io.Writer) WritePNGIENDError!void {
    try writePNGWriteChunk(writer, "IEND".*, "");
}

const WritePNGWriteChunkError = BytesWrittenMismatchError || Io.Writer.Error;

/// Generic chunk writer, used by higher-level chunk writers to process
/// and write the payload.
fn writePNGWriteChunk(writer: *Io.Writer, chunk_type: [4]u8, data: []const u8) WritePNGWriteChunkError!void {
    if (data.len > math.maxInt(u32)) {
        @panic("bad PNG chunk data length (larger than 4GB). this is a bug, please report it");
    }
    const len: u32 = @intCast(data.len);
    const checksum = writePNGChunkCRC(chunk_type, data);

    // Maximum size of a whole chunk is:
    // 16384 (data, maximum zlib chunk size) + 12 (metadata)
    //
    // TODO: May eventually turn this into a buffered writer. The thing is that
    // we already buffer a decent amount in the zlib buffer (as shown above)
    // which will limit the number of writes. The largest file in spec/ as of
    // this comment currently only writes out 7 IDAT chunks.
    //
    // For now, this saves an extra ~16K on the stack.

    try writer.writeInt(u32, len, .big);
    if (try writer.write(&chunk_type) != 4) return error.BytesWrittenMismatch;
    if (try writer.write(data) != data.len) return error.BytesWrittenMismatch;
    try writer.writeInt(u32, checksum, .big);
}

/// Calculates the CRC32 checksum for the chunk.
fn writePNGChunkCRC(chunk_type: [4]u8, data: []const u8) u32 {
    var hasher = crc32.init();
    hasher.update(chunk_type[0..chunk_type.len]);
    hasher.update(data);
    return hasher.final();
}

test "RGB/ARGB formats all export to same image" {
    const Context = @import("Context.zig");
    const hash_bytes_int_T = @Int(.unsigned, sha256.digest_length * 8);
    const alloc = testing.allocator;
    const io = testing.io;
    const width = 300;
    const height = 300;

    // Two groups, one for ARGB/RGBA, and one for XRGB/RGB.
    const TestFn = struct {
        fn run(sfc_type: surface.SurfaceType) !void {
            var expected_hash_: ?[sha256.digest_length]u8 = null;

            var sfc = try surface.Surface.init(sfc_type, alloc, width, height);
            defer sfc.deinit(alloc);
            var context = Context.init(io, alloc, &sfc);
            defer context.deinit();
            context.setSourceToPixel(.{ .rgb = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC } });
            context.setAntiAliasingMode(.default);
            const margin = 10;
            try context.moveTo(0 + margin, 0 + margin);
            try context.lineTo(width - margin - 1, 0 + margin);
            try context.lineTo(width / 2 - 1, height - margin - 1);
            try context.closePath();
            try context.fill();

            var tmp_dir = testing.tmpDir(.{});
            defer tmp_dir.cleanup();
            var parent_path_bytes: [512]u8 = undefined;
            const parent_path_len = try tmp_dir.dir.realPath(io, &parent_path_bytes);
            const parent_path = parent_path_bytes[0..parent_path_len];
            const target_path = try fs.path.join(alloc, &.{ parent_path, "z2d_test.png" });
            defer alloc.free(target_path);
            try writeToPNGFile(
                io,
                sfc,
                target_path,
                .{},
            );

            const actual_data = try Io.Dir.cwd().readFileAlloc(io, target_path, alloc, .limited(10240000));
            defer alloc.free(actual_data);
            if (expected_hash_) |expected_hash| {
                var actual_hash: [sha256.digest_length]u8 = undefined;
                sha256.hash(actual_data, &actual_hash, .{});
                if (!mem.eql(u8, &expected_hash, &actual_hash)) {
                    debug.print(
                        "output mismatch: {s} vs {s}\n",
                        .{
                            fmt.hex(mem.bytesToValue(hash_bytes_int_T, &expected_hash)),
                            fmt.hex(mem.bytesToValue(hash_bytes_int_T, &actual_hash)),
                        },
                    );
                    return error.OutputDoesNotMatch;
                }
            } else {
                expected_hash_ = undefined;
                expected_hash_.? = @splat(0);
                sha256.hash(actual_data, &expected_hash_.?, .{});
            }
        }
    };

    inline for (.{ .image_surface_argb, .image_surface_rgba }) |sfc_type| {
        try TestFn.run(sfc_type);
    }
    inline for (.{ .image_surface_xrgb, .image_surface_rgb }) |sfc_type| {
        try TestFn.run(sfc_type);
    }
}
