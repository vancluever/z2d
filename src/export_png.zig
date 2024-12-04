// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024 Chris Marchesi

//! Rudimentary PNG export functionality.

const builtin = @import("builtin");
const crc32 = @import("std").hash.Crc32;
const fs = @import("std").fs;
const io = @import("std").io;
const mem = @import("std").mem;
const zlib = @import("std").compress.zlib;

const surface = @import("surface.zig");

const native_endian = builtin.cpu.arch.endian();

/// Errors associated with exporting (e.g., to PNG et al).
pub const Error = error{
    /// Error during streaming graphical data.
    BytesWrittenMismatch,

    /// The surface format is unsupported for export.
    UnsupportedSurfaceFormat,
};

/// **Note for autodoc viewers:** Several members of this error set have been
/// obfuscated due to being pruned from autodoc. Please view source for the
/// full set.
pub const WriteToPNGFileError = Error ||
    fs.File.OpenError ||
    zlib.Compressor(io.FixedBufferStream([]u8).Writer).Error ||
    fs.File.WriteError;

/// Exports the surface to a PNG file supplied by filename.
///
/// This is currently a very rudimentary export with default zlib
/// compression and no pixel filtering.
pub fn writeToPNGFile(
    sfc: surface.Surface,
    filename: []const u8,
) WriteToPNGFileError!void {
    // TODO: There are currently no unsupported surface formats, and there
    // might likely not be going forward (we had alpha as an unsupported format
    // but now we just convert it to greyscale). Keeping this here for a bit
    // just in case, but we likely can remove it.
    //
    // switch (sfc.getFormat()) {
    //     .rgba, .rgb, .alpha8 => {},
    //     else => {
    //         return error.UnsupportedSurfaceFormat;
    //     },
    // }

    // Open and create the file.
    const file = try fs.cwd().createFile(filename, .{});
    defer file.close();

    // Write out magic header, and various chunks.
    try writePNGMagic(file);
    try writePNGIHDR(file, sfc);
    try writePNGIDATStream(file, sfc);
    try writePNGIEND(file);
}

/// Writes the magic header for the PNG file.
fn writePNGMagic(file: fs.File) fs.File.WriteError!void {
    const header = "\x89PNG\x0D\x0A\x1A\x0A";
    _ = try file.write(header);
}

/// Writes the IHDR chunk for the PNG file.
fn writePNGIHDR(file: fs.File, sfc: surface.Surface) (Error || fs.File.WriteError)!void {
    var width = [_]u8{0} ** 4;
    var height = [_]u8{0} ** 4;

    mem.writeInt(u32, &width, @intCast(sfc.getWidth()), .big);
    mem.writeInt(u32, &height, @intCast(sfc.getHeight()), .big);
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
) WritePNGIDATStreamError!void {
    // Set a minimum remaining buffer size here that is reasonably
    // sized. This may not be 100% scientific, but should account for
    // the 248 byte deflate buffer (see buffer sizes in the stdlib at
    // deflate/huffman_bit_writer.zig). Coincidentally, 256 here then
    // means that we have 8 bytes of space to write, which should be
    // enough for now (we currently stream up to 5 bytes at a time to
    // the zlib stream).
    //
    // This may change when we start supporting filter algorithms, and
    // have to start writing whole scanlines at once (multiple
    // scanlines, in fact).
    const min_remaining: usize = 256;

    // Our zlib buffer is 8K, but we may add the ability to tune this
    // in the future.
    //
    // NOTE: When allowing for modifications to this value, there
    // likely will need to be a minimum buffer size of ~512 bytes or
    // something else reasonable. This is due to the minimum size we
    // need for headers (see above).
    var zlib_buffer_underlying = [_]u8{0} ** 8192;
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
    for (0..@intCast(sfc.getHeight())) |y| {
        // Initialize a buffer for pixels. TODO: This will need to
        // increase/change when/if we add additional pixel filtering
        // algorithms.
        //
        // Buffer is 5 bytes to accommodate both scanline header and
        // current maximum bpp (which is a u32).
        var pixel_buffer = [_]u8{0} ** 5;
        var nbytes: usize = 1; // Adds scanline header (0x00 - no filtering)

        var x: usize = 0;
        while (x < sfc.getWidth()) : (x += 1) {
            nbytes += written: {
                switch (sfc.getPixel(@intCast(x), @intCast(y)) orelse unreachable) {
                    // PNG writes out numbers big-endian, but *only numbers larger
                    // than a byte*. This means we need to handle each pixel format
                    // slightly differently with how we swap around bytes, etc.
                    // Note that we currently don't support any pixel with a bit
                    // depth larger than 8 bits, so this means we currently take
                    // all formats little-endian completely.
                    .rgb => |px| {
                        mem.copyForwards(
                            u8,
                            pixel_buffer[nbytes..pixel_buffer.len],
                            u32PixelToBytesLittle(@bitCast(px))[0..3],
                        );
                        break :written 3; // 3 bytes
                    },
                    .rgba => |px| {
                        mem.copyForwards(
                            u8,
                            pixel_buffer[nbytes..pixel_buffer.len],
                            &u32PixelToBytesLittle(@bitCast(px.demultiply())),
                        );
                        break :written 4; // 4 bytes
                    },
                    .alpha8 => |px| {
                        mem.copyForwards(
                            u8,
                            pixel_buffer[nbytes..pixel_buffer.len],
                            &@as([1]u8, @bitCast(px)),
                        );
                        break :written 1; // 1 byte
                    },
                    .alpha4 => |px| {
                        // Pack 2 pixels in a single byte, starting with the
                        // one we have right now in the MSB range.
                        pixel_buffer[nbytes] = 0; // zero dirty buffer first
                        const px_u8: u8 = @intCast(@as(u4, @bitCast(px)));
                        pixel_buffer[nbytes] |= px_u8 << 4;
                        x += 1;
                        if (sfc.getPixel(@intCast(x), @intCast(y))) |other_px| {
                            pixel_buffer[nbytes] |= @as(u8, @intCast(@as(u4, @bitCast(other_px.alpha4))));
                        }
                        break :written 1; // 1 byte
                    },
                    .alpha2 => |px| {
                        // Pack 4 pixels in a single byte, starting with the
                        // one we have right now in the MSB range.
                        pixel_buffer[nbytes] = 0; // zero dirty buffer first
                        var px_u8: u8 = @intCast(@as(u2, @bitCast(px)));
                        pixel_buffer[nbytes] |= px_u8 << 6;
                        for (1..4) |i| {
                            x += 1;
                            if (sfc.getPixel(@intCast(x), @intCast(y))) |other_px| {
                                const shl: u3 = @intCast(6 - i * 2);
                                px_u8 = @intCast(@as(u2, @bitCast(other_px.alpha2)));
                                pixel_buffer[nbytes] |= px_u8 << shl;
                            } else {
                                break;
                            }
                        }
                        break :written 1; // 1 byte
                    },
                    .alpha1 => |px| {
                        // Pack 8 pixels in a single byte, starting with the
                        // one we have right now in the MSB.
                        pixel_buffer[nbytes] = 0; // zero dirty buffer first
                        var px_u8: u8 = @intCast(@as(u1, @bitCast(px)));
                        pixel_buffer[nbytes] |= px_u8 << 7;
                        for (1..8) |i| {
                            x += 1;
                            if (sfc.getPixel(@intCast(x), @intCast(y))) |other_px| {
                                const shl: u3 = @intCast(7 - i);
                                px_u8 = @intCast(@as(u1, @bitCast(other_px.alpha1)));
                                pixel_buffer[nbytes] |= px_u8 << shl;
                            } else {
                                break;
                            }
                        }
                        break :written 1; // 1 byte
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

/// Returns a cast of u32 to u8 (little endian).
fn u32PixelToBytesLittle(value: u32) [4]u8 {
    return @bitCast(if (native_endian == .little) value else @byteSwap(value));
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
