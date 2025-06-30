// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024-2025 Chris Marchesi

//! Rudimentary PNG export functionality.

const builtin = @import("builtin");
const crc32 = @import("std").hash.Crc32;
const fs = @import("std").fs;
const io = @import("std").io;
const math = @import("std").math;
const mem = @import("std").mem;
const zlib = @import("std").compress.zlib;

const color = @import("color.zig");
const color_vector = @import("internal/color_vector.zig");
const pixel = @import("pixel.zig");
const pixel_vector = @import("internal/pixel_vector.zig");
const surface = @import("surface.zig");

const vector_length = @import("z2d.zig").vector_length;

const native_endian = builtin.cpu.arch.endian();

/// Errors associated with exporting (e.g., to PNG et al).
pub const Error = error{
    /// Error during streaming graphical data.
    BytesWrittenMismatch,
};

/// **Note for autodoc viewers:** Several members of this error set have been
/// obfuscated due to being pruned from autodoc. Please view source for the
/// full set.
pub const WriteToPNGFileError = Error ||
    fs.File.OpenError ||
    zlib.Compressor(io.FixedBufferStream([]u8).Writer).Error ||
    fs.File.WriteError;

pub const WriteToPNGFileOptions = struct {
    /// The RGB/color profile to use for exporting.
    ///
    /// When set, the gAMA header is set appropriately for the gamma transfer
    /// number, and the image data is re-encoded with the gamma if necessary.
    ///
    /// The default is to not add the gAMA header or encode the gamma.
    color_profile: ?color.RGBProfile = null,
};

/// Exports the surface to a PNG file supplied by filename.
///
/// This is currently a very rudimentary export with default zlib compression
/// and no pixel filtering.
///
/// Additional options to control the export can be supplied in opts.
pub fn writeToPNGFile(
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
    const file = try fs.cwd().createFile(filename, .{});
    defer file.close();

    // Write out magic header, and various chunks.
    try writePNGMagic(file);
    try writePNGIHDR(file, sfc);
    if (opts.color_profile) |profile| try writePNGgAMA(file, profile);
    try writePNGIDATStream(file, sfc, opts.color_profile);
    try writePNGIEND(file);
}

/// Writes the magic header for the PNG file.
fn writePNGMagic(file: fs.File) fs.File.WriteError!void {
    const header = "\x89PNG\x0D\x0A\x1A\x0A";
    _ = try file.write(header);
}

/// Writes the IHDR chunk for the PNG file.
fn writePNGIHDR(file: fs.File, sfc: surface.Surface) fs.File.WriteError!void {
    var width = [_]u8{0} ** 4;
    var height = [_]u8{0} ** 4;

    mem.writeInt(u32, &width, @max(0, sfc.getWidth()), .big);
    mem.writeInt(u32, &height, @max(0, sfc.getHeight()), .big);
    const depth: u8 = switch (sfc.getFormat()) {
        .rgba => 8,
        .rgb => 8,
        .alpha8 => 8,
        .alpha4 => 4,
        .alpha2 => 2,
        .alpha1 => 1,
    };
    const color_type: u8 = switch (sfc.getFormat()) {
        .rgba => 6,
        .rgb => 2,
        .alpha8, .alpha4, .alpha2, .alpha1 => 0,
    };
    const compression: u8 = 0;
    const filter: u8 = 0;
    const interlace: u8 = 0;

    try writePNGWriteChunk(
        file,
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

fn writePNGgAMA(file: fs.File, profile: color.RGBProfile) fs.File.WriteError!void {
    const gamma: u32 = @intFromFloat((switch (profile) {
        .linear => 1 / color.LinearRGB.gamma,
        .srgb => 1 / color.SRGB.gamma,
    }) * 100000);
    var gamma_bytes = [_]u8{0} ** 4;
    mem.writeInt(u32, &gamma_bytes, gamma, .big);
    try writePNGWriteChunk(
        file,
        "gAMA".*,
        &gamma_bytes,
    );
}

const WritePNGIDATStreamError = Error ||
    zlib.Compressor(io.FixedBufferStream([]u8).Writer).Error ||
    fs.File.WriteError;

/// Write the IDAT stream (pixel data) for the PNG file.
///
/// This is currently a very rudimentary algorithm - default zlib
/// compression and no pixel filtering.
fn writePNGIDATStream(
    file: fs.File,
    sfc: surface.Surface,
    profile: ?color.RGBProfile,
) WritePNGIDATStreamError!void {
    const sfc_width: i32 = sfc.getWidth();
    const sfc_height: i32 = sfc.getHeight();

    // Set a minimum remaining buffer size here that is reasonably
    // sized. This may not be 100% scientific, but should account for
    // the 248 byte deflate buffer (see buffer sizes in the stdlib at
    // deflate/huffman_bit_writer.zig) plus 1 full write.
    //
    // This may change when we start supporting filter algorithms, and
    // have to start writing whole scanlines at once (multiple
    // scanlines, in fact).
    const min_remaining: usize = 248 + (4 * vector_length + 1);

    // Our zlib buffer is 16K, but we may add the ability to tune this
    // in the future.
    //
    // NOTE: When allowing for modifications to this value, there
    // likely will need to be a minimum buffer size of ~512 bytes or
    // something else reasonable. This is due to the minimum size we
    // need for headers (see above).
    var zlib_buffer_underlying = [_]u8{0} ** 16384;
    var zlib_buffer = io.fixedBufferStream(&zlib_buffer_underlying);
    var zlib_stream = try zlib.compressor(zlib_buffer.writer(), .{});

    // Initialize our remaining buffer size. We keep track of this as
    // we need to flush regularly to output IDAT chunks.
    var zlib_buffer_remaining = try zlib_buffer.getEndPos() - try zlib_buffer.getPos();

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
                    .rgb => |s| {
                        var stride_vec = [_]u32{0} ** vector_length;
                        @memcpy(stride_vec[0..stride_len], @as([]u32, @ptrCast(s[x .. x + stride_len])));
                        stride_vec = encodeRGBAVec(stride_vec, profile, false);
                        const stride_bytes = u32PixelToBytesLittleVec(stride_vec);
                        for (0..stride_len) |i| {
                            const j = i * 3;
                            const k = i * 4;
                            @memcpy(pixel_buffer[nbytes + j .. nbytes + j + 3], stride_bytes[k .. k + 3]);
                        }
                        break :written stride_len * 3;
                    },
                    .rgba => |s| {
                        var stride_vec = [_]u32{0} ** vector_length;
                        @memcpy(stride_vec[0..stride_len], @as([]u32, @ptrCast(s[x .. x + stride_len])));
                        stride_vec = encodeRGBAVec(stride_vec, profile, true);
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
            if (try zlib_stream.write(pixel_buffer[0..nbytes]) != nbytes) {
                // If we didn't actually write everything, it's an error.
                return error.BytesWrittenMismatch;
            }

            // New remaining at this point is current_remaining - what was
            // written
            zlib_buffer_remaining -= nbytes;

            if (zlib_buffer_remaining < min_remaining) {
                // If we possibly could have less remaining than our minimum
                // buffer size, we need to flush. This should always succeed.
                try zlib_stream.flush();

                // We can now check to see how much remaining is in our
                // underlying buffer.
                if (try zlib_buffer.getEndPos() - try zlib_buffer.getPos() < min_remaining) {
                    // We are now actually below the threshold, so write out an
                    // IDAT chunk, and reset the buffer.
                    try writePNGIDATSingle(file, zlib_buffer.getWritten());
                    zlib_buffer.reset();
                }

                // Actual new remaining is now the amount remaining in the buffer.
                zlib_buffer_remaining = try zlib_buffer.getEndPos() - try zlib_buffer.getPos();
            }

            // Reset nbytes for the next run.
            nbytes = 0;
        }
    }

    // Close off and write the remaining bytes. This should always succeed.
    try zlib_stream.finish();
    try writePNGIDATSingle(file, zlib_buffer.getWritten());
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
    comptime use_alpha: bool,
) [vector_length]u32 {
    var rgba_vector: pixel_vector.RGBA16 = undefined;
    for (0..vector_length) |i| {
        const rgba_scalar: pixel.RGBA = @bitCast(value[i]);
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
    for (0..vector_length) |i| {
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

/// Writes a single IDAT chunk. The data should be part of the zlib
/// stream. See writePNG_IDAT_stream et al.
fn writePNGIDATSingle(file: fs.File, data: []const u8) fs.File.WriteError!void {
    try writePNGWriteChunk(file, "IDAT".*, data);
}

/// Write the IEND chunk.
fn writePNGIEND(file: fs.File) fs.File.WriteError!void {
    try writePNGWriteChunk(file, "IEND".*, "");
}

/// Generic chunk writer, used by higher-level chunk writers to process
/// and write the payload.
fn writePNGWriteChunk(file: fs.File, chunk_type: [4]u8, data: []const u8) fs.File.WriteError!void {
    if (data.len > math.maxInt(u32)) {
        @panic("bad PNG chunk data length (larger than 4GB). this is a bug, please report it");
    }
    const len: u32 = @intCast(data.len);
    const checksum = writePNGChunkCRC(chunk_type, data);

    _ = try file.writer().writeInt(u32, len, .big);
    _ = try file.write(&chunk_type);
    _ = try file.write(data);
    _ = try file.writer().writeInt(u32, checksum, .big);
}

/// Calculates the CRC32 checksum for the chunk.
fn writePNGChunkCRC(chunk_type: [4]u8, data: []const u8) u32 {
    var hasher = crc32.init();
    hasher.update(chunk_type[0..chunk_type.len]);
    hasher.update(data);
    return hasher.final();
}
