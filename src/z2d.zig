//! z2d - a Zig 2D graphics library
//!
const builtin = @import("builtin");
const std = @import("std");
const native_endian = builtin.cpu.arch.endian();

////////////////////////////////////////
// Pixel formats
////////////////////////////////////////

/// Describes a 32-bit RGBA format.
pub const RGBA = packed struct(u32) {
    r: u8,
    g: u8,
    b: u8,
    a: u8,

    /// The format descriptor for this pixel format.
    const format: PixelFormat = .rgba;

    /// Returns this pixel as the slice of its bytes, in big-endian form. Any
    /// padding is removed.
    fn asBytesBig(self: RGBA) []const u8 {
        var start: usize = 0;
        _ = &start;
        return u32ToBytes(@bitCast(self))[start..];
    }
};

/// Describes a 24-bit RGB format.
pub const RGB = packed struct(u32) {
    r: u8,
    g: u8,
    b: u8,
    _padding: u8 = 0,

    /// The format descriptor for this pixel format.
    const format: PixelFormat = .rgb;

    /// Returns this pixel as the slice of its bytes, in big-endian form. Any
    /// padding is removed.
    fn asBytesBig(self: RGB) []const u8 {
        var start: usize = 1;
        _ = &start;
        return u32ToBytes(@bitCast(self))[start..];
    }
};

/// Format descriptors for the pixel formats supported by the library:
///
/// * .rgba is 24-bit truecolor as a 8-bit depth RGB, *with* alpha channel.
/// * .rgb is 24-bit truecolor as a 8-bit depth RGB, *without* alpha channel.
const PixelFormat = enum {
    rgba,
    rgb,

    /// Returns the type for this pixel format.
    fn asType(self: PixelFormat) type {
        return switch (self) {
            .rgba => RGBA,
            .rgb => RGB,
        };
    }
};

////////////////////////////////////////
// Graphics surfaces
////////////////////////////////////////

/// A memory-backed image surface. The pixel format is the type (e.g. RGB or
/// RGBA). Call init to return an initialized surface.
pub fn ImageSurface(comptime T: type) type {
    return struct {
        /// The height of the surface.
        height: u32,

        /// The width of the surface.
        width: u32,

        /// The underlying allocator, only needed for deinit. Should not be
        /// used.
        alloc: std.mem.Allocator,

        /// The underlying buffer. It's not advised to access this directly,
        /// rather use pixel operations such as getPixel and putPixel.
        ///
        /// The buffer is initialized to height * width on initialization,
        /// de-allocated on deinit, and is invalid to use after the latter is
        /// called.
        buf: []T,

        /// Returns the format for the surface.
        pub fn pixelFormat() PixelFormat {
            return T.format;
        }

        /// De-allocates the surface buffer. The surface is invalid for use after
        /// this is called.
        pub fn deinit(self: *ImageSurface(T)) void {
            self.alloc.free(self.buf);
        }

        /// Gets the pixel data at the co-ordinates specified.
        pub fn getPixel(self: *ImageSurface(T), x: u32, y: u32) !T {
            // Check that data is in the surface range. If not, return an error.
            if (x >= self.width or y >= self.height) {
                return error.ImageSurfaceGetPixelOutOfRange;
            }

            return self.buf[self.width * y + x];
        }

        /// Puts a single pixel at the x and y co-ordinates.
        pub fn putPixel(self: *ImageSurface(T), x: u32, y: u32, pixel: T) !void {
            // Check that data is in the surface range. If not, return an error.
            if (x >= self.width or y >= self.height) {
                return error.ImageSurfacePutPixelOutOfRange;
            }

            // std.log.debug("surface ptr: {?}", .{self});
            // std.log.debug("self.w: {}, y: {} x: {}", .{ self.width, y, x });
            self.buf[self.width * y + x] = pixel;
        }

        /// Initializes the surface. deinit should be called when finished with
        /// the surface, which invalidates it, after which it should not be
        /// used.
        pub fn init(alloc: std.mem.Allocator, height: u32, width: u32) !ImageSurface(T) {
            const buf = try alloc.alloc(T, height * width);
            @memset(buf, std.mem.zeroes(T));
            return .{
                .alloc = alloc,
                .height = height,
                .width = width,
                .buf = buf,
            };
        }
    };
}

////////////////////////////////////////
// Exporting
////////////////////////////////////////

/// An exporter that can be used to write surface data to a PNG file. Supply
/// the pixel format of the surface type (e.g. RGB or RGBA).
pub fn PNGExporter(comptime T: type) type {
    return struct {
        /// Exports the surface to a PNG file supplied by filename.
        ///
        /// This is currently a very rudimentary export with default zlib
        /// compression and no pixel filtering.
        pub fn writeToFile(
            alloc: std.mem.Allocator,
            surface: ImageSurface(T),
            filename: []const u8,
        ) !void {
            // Open and create the file.
            const file = try std.fs.cwd().createFile(filename, .{});
            defer file.close();

            // Write out magic header, and various chunks.
            try writePNG_magic(file);
            try writePNG_IHDR(file, surface);
            try writePNG_IDAT_stream(alloc, file, surface);
            try writePNG_IEND(file);
        }

        /// Writes the magic header for the PNG file.
        fn writePNG_magic(file: std.fs.File) !void {
            const header = "\x89PNG\x0D\x0A\x1A\x0A";
            _ = try file.write(header);
        }

        /// Writes the IHDR chunk for the PNG file.
        fn writePNG_IHDR(file: std.fs.File, surface: ImageSurface(T)) !void {
            var width = [_]u8{0} ** 4;
            var height = [_]u8{0} ** 4;

            std.mem.writeInt(u32, &width, surface.width, .big);
            std.mem.writeInt(u32, &height, surface.height, .big);
            const depth: u8 = switch (T.format) {
                .rgba => 8,
                .rgb => 8,
            };
            const color_type: u8 = switch (T.format) {
                .rgba => 6,
                .rgb => 2,
            };
            const compression: u8 = 0;
            const filter: u8 = 0;
            const interlace: u8 = 0;

            try writePNG_writeChunk(
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

        /// Write the IDAT stream (pixel data) for the PNG file.
        ///
        /// This is currently a very rudimentary algorithm - default zlib
        /// compression and no pixel filtering.
        fn writePNG_IDAT_stream(
            alloc: std.mem.Allocator,
            file: std.fs.File,
            surface: ImageSurface(T),
        ) !void {
            // Our zlib buffer is 8K, but we may add the ability to tune this
            // in the future.
            //
            // NOTE: When allowing for modifications to this value, there
            // likely will need to be a minimum buffer size of ~512 bytes or
            // something else reasonable. This is due to the minimum size we
            // need for headers. See writePNG_IDAT_writeBytes2.
            var zlib_buffer_underlying = [_]u8{0} ** 8192;
            var zlib_buffer = std.io.fixedBufferStream(&zlib_buffer_underlying);
            var zlib_stream = try std.compress.zlib.compressStream(alloc, zlib_buffer.writer(), .{});
            defer zlib_stream.deinit();

            // Initialize our remaining buffer size. We keep track of this as
            // we need to flush regularly to output IDAT chunks.
            //
            // TODO: We should probably move this to a dedicated writer struct.
            var remaining = try zlib_buffer.getEndPos() - try zlib_buffer.getPos();

            // Read from the buffer, pixel-by-pixel, and write out depending on our
            // endianness, and also the format that we use. Iteration and coercion is
            // handled by the iterator.
            std.log.debug("surface.buf.len: {}", .{surface.buf.len});
            // Iterate through each line to encode as scanlines.
            for (0..surface.height) |y| {
                const line_start = y * surface.width;
                const line_end = line_start + surface.width;
                // Write scanline header (0x00 - no filtering). TODO: add filtering ;)
                remaining = try writePNG_IDAT_writeBytes(
                    file,
                    &zlib_stream,
                    &zlib_buffer,
                    &[_]u8{0},
                    remaining,
                );
                for (surface.buf[line_start..line_end]) |pixel| {
                    // Write to stream. This will send IDAT packets once the buffer is full.
                    remaining = try writePNG_IDAT_writeBytes(
                        file,
                        &zlib_stream,
                        &zlib_buffer,
                        pixel.asBytesBig(),
                        remaining,
                    );
                }
            }

            // Close off and write the remaining bytes. This should always succeed.
            try zlib_stream.finish();
            try writePNG_IDAT_single(file, zlib_buffer.getWritten());
        }

        fn writePNG_IDAT_writeBytes(
            file: std.fs.File,
            zlib_stream: *std.compress.zlib.CompressStream(std.io.FixedBufferStream([]u8).Writer),
            zlib_buffer: *std.io.FixedBufferStream([]u8),
            bytes: []const u8,
            current_remaining: usize,
        ) !usize {
            // Set a minimum remaining buffer here that is reasonably sized.
            // This may not be 100% scientific, but should account for the 248
            // byte deflate buffer (see buffer sizes in
            // deflate/huffman_bit_writer.zig). Coincidentally, 256 here then
            // means that we have 8 bytes of space to write, which should be
            // plenty for now - but of course, this will change when we start
            // supporting filter algorithms, and have to start writing whole
            // scanlines at once (multiple scanlines, in fact).
            const min_remaining: usize = 256;

            const expected_written = bytes.len;
            const actual_written = try zlib_stream.write(bytes);
            if (expected_written != actual_written) {
                // If we didn't actually write everything, it's an error.
                return error.WritePNGIDATBytesWrittenMismatch;
            }

            // New remaining at this point is current_remaining - what was
            // written
            var new_remaining = current_remaining - actual_written;
            if (new_remaining < min_remaining) {
                // If we possibly could have less remaining than our minimum
                // buffer size, we need to flush. This should always succeed.
                try zlib_stream.deflator.flush();

                // We can now check to see how much remaining is in our
                // underlying buffer.
                if (try zlib_buffer.getEndPos() - try zlib_buffer.getPos() < min_remaining) {
                    // We are now actually below the threshold, so write out an
                    // IDAT chunk, and reset the buffer.
                    try writePNG_IDAT_single(file, zlib_buffer.getWritten());
                    zlib_buffer.reset();
                }

                // Actual new remaining is now the amount remaining in the buffer.
                new_remaining = try zlib_buffer.getEndPos() - try zlib_buffer.getPos();
            }

            return new_remaining;
        }

        /// Writes a single IDAT chunk. The data should be part of the zlib
        /// stream. See writePNG_IDAT_stream et al.
        fn writePNG_IDAT_single(file: std.fs.File, data: []const u8) !void {
            try writePNG_writeChunk(file, "IDAT".*, data);
        }

        /// Write the IEND chunk.
        fn writePNG_IEND(file: std.fs.File) !void {
            try writePNG_writeChunk(file, "IEND".*, "");
        }

        /// Generic chunk writer, used by higher-level chunk writers to process
        /// and write the payload.
        fn writePNG_writeChunk(file: std.fs.File, chunk_type: [4]u8, data: []const u8) !void {
            const len: u32 = @intCast(data.len);
            const checksum = writePNG_chunkCRC(chunk_type, data);

            _ = try file.writer().writeInt(u32, len, .big);
            _ = try file.write(&chunk_type);
            _ = try file.write(data);
            _ = try file.writer().writeInt(u32, checksum, .big);
        }

        /// Calculates the CRC32 checksum for the chunk.
        fn writePNG_chunkCRC(chunk_type: [4]u8, data: []const u8) u32 {
            var hasher = std.hash.Crc32.init();
            hasher.update(chunk_type[0..chunk_type.len]);
            hasher.update(data);
            return hasher.final();
        }
    };
}

////////////////////////////////////////
// Utility functions
////////////////////////////////////////

/// Returns a cast of u32 to u8 (big-endian). Used to cast pixels for image
/// export.
fn u32ToBytes(value: u32) [4]u8 {
    return @bitCast(if (native_endian == .big) value else @byteSwap(value));
}
