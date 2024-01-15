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
        return u32ToBytes(@bitCast(self), .big)[start..];
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
        return u32ToBytes(@bitCast(self), .big)[start..];
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

        /// Creates a context for this surface, connecting it to a pattern.
        pub fn createContext(
            self: *ImageSurface(T),
            comptime pattern_T: type,
            pattern: pattern_T,
        ) DrawContext(*ImageSurface(T), pattern_T) {
            return .{
                .surface = self,
                .pattern = pattern,
            };
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
// Patterns
////////////////////////////////////////

/// A simple opaque color pattern that writes the set color to every pixel.
pub fn OpaquePattern(comptime T: type) type {
    return struct {
        pixel: T,

        /// Returns the pixel for a particular co-ordinate. Transformed for the
        /// destination pixel type.
        ///
        /// NOTE: x and y are unused for opaque surfaces, but must be provided
        /// for implementation's sake.
        fn pixelFor(self: *OpaquePattern(T), comptime dest_T: type, x: u32, y: u32) dest_T {
            // x and y are unused for opaque surfaces
            _ = x;
            _ = y;

            // Comptime check to make sure that our source and dest are
            // compatible. Currently, our pixel formats (RGBA and RGB) are both
            // u32, so we can shortcut and bitCast, but in the future this may
            // not be the case, so I want to introduce this pattern now.
            switch (@TypeOf(self.pixel)) {
                RGBA => {},
                RGB => {},
                else => @compileError("invalid pixel type for pixelFor conversion"),
            }

            switch (dest_T) {
                RGBA => {},
                RGB => {},
                else => @compileError("invalid destination pixel type for pixelFor conversion"),
            }

            // Bitcast directly from source to dest.
            return @bitCast(self.pixel);
        }
    };
}

////////////////////////////////////////
// Drawing context
////////////////////////////////////////

/// The drawing context. Holds information about a surface and a pattern.
/// Further operations will use the described pattern to write to the underlying
/// surface. Note that it is valid to have multiple contexts write to the same
/// surface, each associated with a different pattern.
pub fn DrawContext(comptime surface_T: type, pattern_T: type) type {
    return struct {
        surface: surface_T,
        pattern: pattern_T,
    };
}

////////////////////////////////////////
// Drawing operations
////////////////////////////////////////

/// Represents a point in 2D space.
pub const Point = struct {
    x: f64,
    y: f64,
};

/// Represents a moveto path node. This starts a new subpath and moves the
/// current point to (x, y).
const PathMoveTo = struct {
    point: Point,
};

/// Represents a lineto path node. This draws a line to (x, y) and sets it as
/// its current point.
const PathLineTo = struct {
    point: Point,
};

/// Represents a curveto path node. This draws a cubic bezier with the three
/// supplied control points from the current point. The new current point is
/// set to p3.
const PathCurveTo = struct {
    p1: Point,
    p2: Point,
    p3: Point,
};

/// A tagged union of all path node types.
const PathNodeTag = enum {
    move_to,
    line_to,
    curve_to,
};

const PathNode = union(PathNodeTag) {
    move_to: PathMoveTo,
    line_to: PathLineTo,
    curve_to: PathCurveTo,
};

/// A path drawing operation, resulting in a rendered complex set of one or
/// more polygons.
pub fn PathOperation(comptime draw_context_T: type) type {
    return struct {
        /// A reference back to the draw context.
        context: draw_context_T,

        /// The set of path nodes.
        nodes: std.ArrayList(PathNode),

        /// The start of the current subpath when working with drawing
        /// operations.
        start_point: ?Point = null,

        /// The current point when working with drawing operations.
        current_point: ?Point = null,

        /// Initializes the path operation. Call deinit to release the node
        /// list when complete.
        pub fn init(alloc: std.mem.Allocator, context: draw_context_T) PathOperation(draw_context_T) {
            return .{
                .context = context,
                .nodes = std.ArrayList(PathNode).init(alloc),
            };
        }

        /// Releases the path node array list. It's invalid to use the
        /// operation after this call.
        pub fn deinit(self: *PathOperation(draw_context_T)) void {
            self.nodes.deinit();
        }

        /// Starts a new path, and moves the current point to it.
        pub fn moveTo(self: *PathOperation(draw_context_T), point: Point) !void {
            try self.nodes.append(.{ .move_to = .{ .point = point } });
            self.start_point = point;
            self.current_point = point;
        }

        /// Draws a line from the current point to the specified point and sets
        /// it as the current point.
        ///
        /// Acts as a moveTo instead if there is no current point.
        pub fn lineTo(self: *PathOperation(draw_context_T), point: Point) !void {
            if (self.current_point == null) return self.moveTo(point);
            try self.nodes.append(.{ .line_to = .{ .point = point } });
            self.current_point = point;
        }

        /// Draws a cubic bezier with the three supplied control points from
        /// the current point. The new current point is set to p3.
        ///
        /// It is an error to call this without a current point.
        pub fn curveTo(self: *PathOperation(draw_context_T), p1: Point, p2: Point, p3: Point) !void {
            if (self.current_point == null) return error.PathOperationCurveToNoCurrentPoint;
            try self.nodes.append(.{ .curve_to = .{ .p1 = p1, .p2 = p2, .p3 = p3 } });
            self.current_point = p3;
        }

        /// Closes the path by drawing a line from the current point by the
        /// starting point. No effect if there is no current point.
        pub fn closePath(self: *PathOperation(draw_context_T)) !void {
            if (self.current_point == null) return;
            try self.nodes.append(.{ .line_to = .{ .point = self.current_point.? } });
            self.current_point = self.start_point;
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
            try writePNGMagic(file);
            try writePNGIHDR(file, surface);
            try writePNGIDATStream(alloc, file, surface);
            try writePNGIEND(file);
        }

        /// Writes the magic header for the PNG file.
        fn writePNGMagic(file: std.fs.File) !void {
            const header = "\x89PNG\x0D\x0A\x1A\x0A";
            _ = try file.write(header);
        }

        /// Writes the IHDR chunk for the PNG file.
        fn writePNGIHDR(file: std.fs.File, surface: ImageSurface(T)) !void {
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

        /// Write the IDAT stream (pixel data) for the PNG file.
        ///
        /// This is currently a very rudimentary algorithm - default zlib
        /// compression and no pixel filtering.
        fn writePNGIDATStream(
            alloc: std.mem.Allocator,
            file: std.fs.File,
            surface: ImageSurface(T),
        ) !void {
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
            var zlib_buffer = std.io.fixedBufferStream(&zlib_buffer_underlying);
            var zlib_stream = try std.compress.zlib.compressStream(alloc, zlib_buffer.writer(), .{});
            defer zlib_stream.deinit();

            // Initialize our remaining buffer size. We keep track of this as
            // we need to flush regularly to output IDAT chunks.
            //
            // TODO: We should probably move this to a dedicated writer struct.
            var zlib_buffer_remaining = try zlib_buffer.getEndPos() - try zlib_buffer.getPos();

            // To encode, we read from our buffer, pixel-by-pixel, and convert
            // to a writable format (big-endian, no padding). We also need to
            // add scanline filtering headers were appropriate.
            //
            // Iterate through each line to encode as scanlines.
            for (0..surface.height) |y| {
                // Scanline indexes
                const line_start = y * surface.width;
                const line_end = line_start + surface.width;

                // Initialize a buffer for pixels. TODO: This will need to
                // increase/change when/if we add additional pixel filtering
                // algorithms.
                //
                // Buffer is 5 bytes to accommodate both scanline header and
                // current maximum bpp (which is a u32).
                var pixel_buffer = [_]u8{0} ** 5;
                var nbytes: usize = 1; // Adds scanline header (0x00 - no filtering)

                for (surface.buf[line_start..line_end]) |pixel| {
                    // Write to pixel buffer
                    std.mem.copyForwards(u8, pixel_buffer[nbytes..pixel_buffer.len], pixel.asBytesBig());
                    nbytes += pixel.asBytesBig().len;
                    if (try zlib_stream.write(pixel_buffer[0..nbytes]) != nbytes) {
                        // If we didn't actually write everything, it's an error.
                        return error.WritePNGIDATBytesWrittenMismatch;
                    }

                    // New remaining at this point is current_remaining - what was
                    // written
                    zlib_buffer_remaining -= nbytes;

                    if (zlib_buffer_remaining < min_remaining) {
                        // If we possibly could have less remaining than our minimum
                        // buffer size, we need to flush. This should always succeed.
                        try zlib_stream.deflator.flush();

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

        /// Writes a single IDAT chunk. The data should be part of the zlib
        /// stream. See writePNG_IDAT_stream et al.
        fn writePNGIDATSingle(file: std.fs.File, data: []const u8) !void {
            try writePNGWriteChunk(file, "IDAT".*, data);
        }

        /// Write the IEND chunk.
        fn writePNGIEND(file: std.fs.File) !void {
            try writePNGWriteChunk(file, "IEND".*, "");
        }

        /// Generic chunk writer, used by higher-level chunk writers to process
        /// and write the payload.
        fn writePNGWriteChunk(file: std.fs.File, chunk_type: [4]u8, data: []const u8) !void {
            const len: u32 = @intCast(data.len);
            const checksum = writePNGChunkCRC(chunk_type, data);

            _ = try file.writer().writeInt(u32, len, .big);
            _ = try file.write(&chunk_type);
            _ = try file.write(data);
            _ = try file.writer().writeInt(u32, checksum, .big);
        }

        /// Calculates the CRC32 checksum for the chunk.
        fn writePNGChunkCRC(chunk_type: [4]u8, data: []const u8) u32 {
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
fn u32ToBytes(value: u32, endian: std.builtin.Endian) [4]u8 {
    return @bitCast(if (native_endian == endian) value else @byteSwap(value));
}
