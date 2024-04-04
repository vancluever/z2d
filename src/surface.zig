const mem = @import("std").mem;
const meta = @import("std").meta;
const testing = @import("std").testing;

const pixelpkg = @import("pixel.zig");

// The scale factor used for super-sample anti-aliasing. Any functionality
// using the downsample method in a surface should import this value.
pub const supersample_scale = 4;

/// Interface tags for surface types.
pub const SurfaceType = enum {
    image_surface_rgb,
    image_surface_rgba,
    image_surface_alpha8,

    fn toPixelType(self: SurfaceType) !type {
        return switch (self) {
            .image_surface_rgb => pixelpkg.RGB,
            .image_surface_rgba => pixelpkg.RGBA,
            .image_surface_alpha8 => pixelpkg.Alpha8,
        };
    }
};

/// Represents an interface as a union of the pixel formats.
pub const Surface = union(SurfaceType) {
    image_surface_rgb: *ImageSurface(pixelpkg.RGB),
    image_surface_rgba: *ImageSurface(pixelpkg.RGBA),
    image_surface_alpha8: *ImageSurface(pixelpkg.Alpha8),

    /// Initializes a surface of the specific type. The surface buffer is
    /// initialized with the zero value for the pixel type (typically black or
    /// transparent).
    ///
    /// The caller owns the memory, so make sure to call deinit to release it.
    pub fn init(
        surface_type: SurfaceType,
        alloc: mem.Allocator,
        width: u32,
        height: u32,
    ) !Surface {
        switch (surface_type) {
            inline else => |t| {
                const pt = try t.toPixelType();
                const sfc = try alloc.create(ImageSurface(pt));
                errdefer alloc.destroy(sfc);
                sfc.* = try ImageSurface(pt).init(alloc, width, height, null);
                return sfc.asSurfaceInterface();
            },
        }
    }

    /// Initializes a surface with the buffer set to the supplied pixel. The
    /// surface type is inferred from it.
    ///
    /// The caller owns the memory, so make sure to call deinit to release it.
    pub fn initPixel(
        initial_px: pixelpkg.Pixel,
        alloc: mem.Allocator,
        width: u32,
        height: u32,
    ) !Surface {
        switch (initial_px) {
            inline else => |px| {
                const sfc = try alloc.create(ImageSurface(@TypeOf(px)));
                errdefer alloc.destroy(sfc);
                sfc.* = try ImageSurface(@TypeOf(px)).init(alloc, width, height, px);
                return sfc.asSurfaceInterface();
            },
        }
    }

    /// Releases the underlying surface memory. The surface is invalid to use
    /// after calling this.
    pub fn deinit(self: Surface) void {
        // NOTE: We use the allocator bound to the surface to free the surface
        // instance itself (not just the buffer) ONLY in the interface. This
        // ensures the generic type value does not get invalidated by a deinit
        // when used outside of the interface (likely, we would only be doing
        // this internally, but I think it's important to make the
        // distinction).
        switch (self) {
            inline else => |s| {
                s.deinit();
                s.alloc.destroy(s);
            },
        }
    }

    /// Downsamples the image, using simple pixel averaging. The original
    /// surface is not altered.
    ///
    /// Uses the same allocator as the original surface. deinit should be
    /// called when finished with the surface, which invalidates it, after
    /// which it should not be used.
    pub fn downsample(self: Surface) !Surface {
        // Our initialization process is the same here as init, since we are
        // creating a new surface for the downsampled copy.
        switch (self) {
            inline else => |s, tag| {
                const pt = try tag.toPixelType();
                const sfc = try s.alloc.create(ImageSurface(pt));
                errdefer s.alloc.destroy(sfc);
                sfc.* = try s.downsample();
                return sfc.asSurfaceInterface();
            },
        }
    }

    /// Composites the source surface onto this surface using the Porter-Duff
    /// src-over operation at the destination. Any parts of the source outside
    /// of the destination are ignored.
    pub fn srcOver(dst: Surface, src: Surface, dst_x: u32, dst_y: u32) !void {
        return switch (dst) {
            inline else => |s| s.srcOver(src, dst_x, dst_y),
        };
    }

    /// Composites the source surface onto this surface using the Porter-Duff
    /// dst-in operation at the destination. Any parts of the source outside
    /// of the destination are ignored.
    pub fn dstIn(dst: Surface, src: Surface, dst_x: u32, dst_y: u32) !void {
        return switch (dst) {
            inline else => |s| s.dstIn(src, dst_x, dst_y),
        };
    }

    /// Gets the width of the surface.
    pub fn getWidth(self: Surface) u32 {
        return switch (self) {
            inline else => |s| s.width,
        };
    }

    /// Gets the height of the surface.
    pub fn getHeight(self: Surface) u32 {
        return switch (self) {
            inline else => |s| s.height,
        };
    }

    /// Gets the pixel format of the surface.
    pub fn getFormat(self: Surface) pixelpkg.Format {
        return switch (self) {
            inline else => |s| @TypeOf(s.*).format,
        };
    }

    /// Gets the pixel data at the co-ordinates specified.
    pub fn getPixel(self: Surface, x: u32, y: u32) !pixelpkg.Pixel {
        return switch (self) {
            inline else => |s| s.getPixel(x, y),
        };
    }

    /// Puts a single pixel at the x and y co-ordinates.
    pub fn putPixel(self: Surface, x: u32, y: u32, px: pixelpkg.Pixel) !void {
        return switch (self) {
            inline else => |s| s.putPixel(x, y, px),
        };
    }

    /// Replaces the surface with the supplied pixel.
    pub fn paintPixel(self: Surface, px: pixelpkg.Pixel) !void {
        return switch (self) {
            inline else => |s| s.paintPixel(px),
        };
    }
};

test "Surface interface" {
    {
        // RGB
        const sfc_if = try Surface.init(.image_surface_rgb, testing.allocator, 20, 10);
        defer sfc_if.deinit();

        // getters
        try testing.expectEqual(20, sfc_if.getWidth());
        try testing.expectEqual(10, sfc_if.getHeight());
        try testing.expectEqual(.rgb, sfc_if.getFormat());

        // putPixel
        const rgb: pixelpkg.RGB = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC };
        const pix_rgb = rgb.asPixel();
        const x: u32 = 7;
        const y: u32 = 5;

        try sfc_if.putPixel(x, y, pix_rgb);

        // getPixel
        try testing.expectEqual(pix_rgb, sfc_if.getPixel(x, y));
    }

    {
        // RGBA
        const sfc_if = try Surface.init(.image_surface_rgba, testing.allocator, 20, 10);
        defer sfc_if.deinit();

        // getters
        try testing.expectEqual(20, sfc_if.getWidth());
        try testing.expectEqual(10, sfc_if.getHeight());
        try testing.expectEqual(.rgba, sfc_if.getFormat());

        // putPixel
        const rgba: pixelpkg.RGBA = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC, .a = 0xDD };
        const pix_rgba = rgba.asPixel();
        const x: u32 = 7;
        const y: u32 = 5;

        try sfc_if.putPixel(x, y, pix_rgba);

        // getPixel
        try testing.expectEqual(pix_rgba, sfc_if.getPixel(x, y));
    }
}

/// A memory-backed image surface. The pixel format is the type (e.g. RGB or
/// RGBA). Call init to return an initialized surface.
fn ImageSurface(comptime T: type) type {
    return struct {
        /// The underlying allocator, only needed for deinit.
        ///
        /// private: should not be edited directly.
        alloc: mem.Allocator,

        /// The width of the surface.
        ///
        /// read-only: should not be modified directly.
        width: u32,

        /// The height of the surface.
        ///
        /// read-only: should not be modified directly.
        height: u32,

        /// The underlying buffer. It's not advised to access this directly,
        /// rather use pixel operations such as getPixel and putPixel.
        ///
        /// The buffer is initialized to height * width on initialization,
        /// de-allocated on deinit, and is invalid to use after the latter is
        /// called.
        ///
        /// private: should not be edited directly.
        buf: []T,

        /// The format for the surface.
        ///
        /// read-only: should not be modified directly.
        pub const format: pixelpkg.Format = T.format;

        /// Initializes a surface. deinit should be called when finished with
        /// the surface, which invalidates it, after which it should not be
        /// used. If non-null, the surface is initialized with the supplied
        /// pixel.
        pub fn init(
            alloc: mem.Allocator,
            width: u32,
            height: u32,
            initial_px_: ?T,
        ) !ImageSurface(T) {
            const buf = try alloc.alloc(T, height * width);
            if (initial_px_) |initial_px| {
                @memset(buf, initial_px);
            } else {
                @memset(buf, mem.zeroes(T));
            }

            return .{
                .alloc = alloc,
                .width = width,
                .height = height,
                .buf = buf,
            };
        }

        /// De-allocates the surface buffer. The surface is invalid for use after
        /// this is called.
        pub fn deinit(self: *ImageSurface(T)) void {
            self.alloc.free(self.buf);
        }

        /// Downsamples the image, using simple pixel averaging. The original
        /// surface is not altered.
        ///
        /// Uses the same allocator as the original surface. deinit should be
        /// called when finished with the surface, which invalidates it, after
        /// which it should not be used.
        pub fn downsample(self: *ImageSurface(T)) !ImageSurface(T) {
            const scale = supersample_scale;
            const height = self.height / scale;
            const width = self.width / scale;
            const buf = try self.alloc.alloc(T, height * width);
            @memset(buf, mem.zeroes(T));

            for (0..height) |y| {
                for (0..width) |x| {
                    var pixels = [_]T{mem.zeroes(T)} ** (scale * scale);
                    for (0..scale) |i| {
                        for (0..scale) |j| {
                            const idx = (y * scale + i) * self.width + (x * scale + j);
                            pixels[i * scale + j] = self.buf[idx];
                        }
                    }
                    buf[y * width + x] = T.average(&pixels);
                }
            }

            return .{
                .alloc = self.alloc,
                .width = width,
                .height = height,
                .buf = buf,
            };
        }

        /// Composites the source surface onto this surface using the
        /// Porter-Duff src-over operation at the destination. Any parts of the
        /// source outside of the destination are ignored.
        pub fn srcOver(dst: *ImageSurface(T), src: Surface, dst_x: u32, dst_y: u32) !void {
            return dst.composite(src, T.srcOver, dst_x, dst_y);
        }

        /// Composites the source surface onto this surface using the
        /// Porter-Duff dst-in operation at the destination. Any parts of the
        /// source outside of the destination are ignored.
        pub fn dstIn(dst: *ImageSurface(T), src: Surface, dst_x: u32, dst_y: u32) !void {
            return dst.composite(src, T.dstIn, dst_x, dst_y);
        }

        fn composite(
            dst: *ImageSurface(T),
            src: Surface,
            op: fn (T, pixelpkg.Pixel) T,
            dst_x: u32,
            dst_y: u32,
        ) !void {
            if (dst_x >= dst.width or dst_y >= dst.height) return;

            var height = src.getHeight();
            if (src.getHeight() + dst_y > dst.height) {
                height -= src.getHeight() + dst_y - dst.height;
            }
            var width = src.getWidth();
            if (src.getWidth() + dst_x > dst.width) {
                width -= src.getWidth() + dst_x - dst.width;
            }

            for (0..height) |src_y| {
                for (0..width) |src_x| {
                    const dst_put_x = src_x + dst_x;
                    const dst_put_y = src_y + dst_y;
                    const dst_idx = dst.width * dst_put_y + dst_put_x;
                    const src_px = try src.getPixel(@intCast(src_x), @intCast(src_y));
                    const dst_px = dst.buf[dst_idx];
                    dst.buf[dst_idx] = op(dst_px, src_px);
                }
            }
        }

        /// Returns a Surface interface for this surface.
        pub fn asSurfaceInterface(self: *ImageSurface(T)) Surface {
            return switch (T.format) {
                .rgba => .{ .image_surface_rgba = self },
                .rgb => .{ .image_surface_rgb = self },
                .alpha8 => .{ .image_surface_alpha8 = self },
            };
        }

        /// Gets the pixel data at the co-ordinates specified.
        pub fn getPixel(self: *ImageSurface(T), x: u32, y: u32) !pixelpkg.Pixel {
            // Check that data is in the surface range. If not, return an error.
            if (x >= self.width or y >= self.height) {
                return error.ImageSurfaceGetPixelOutOfRange;
            }

            return self.buf[self.width * y + x].asPixel();
        }

        /// Puts a single pixel at the x and y co-ordinates.
        pub fn putPixel(self: *ImageSurface(T), x: u32, y: u32, px: pixelpkg.Pixel) !void {
            // Check that data is in the surface range. If not, return an error.
            if (x >= self.width or y >= self.height) {
                return error.ImageSurfacePutPixelOutOfRange;
            }
            self.buf[self.width * y + x] = try T.fromPixel(px);
        }

        /// Replaces the surface with the supplied pixel.
        pub fn paintPixel(self: *ImageSurface(T), px: pixelpkg.Pixel) !void {
            @memset(self.buf, try T.fromPixel(px));
        }
    };
}

test "ImageSurface, init, deinit" {
    const sfc_T = ImageSurface(pixelpkg.RGBA);
    var sfc = try sfc_T.init(testing.allocator, 10, 20, null);
    defer sfc.deinit();

    try testing.expectEqual(20, sfc.height);
    try testing.expectEqual(10, sfc.width);
    try testing.expectEqual(200, sfc.buf.len);
    try testing.expectEqual(meta.Elem(@TypeOf(sfc.buf)), pixelpkg.RGBA);
    try testing.expectEqualSlices(
        pixelpkg.RGBA,
        sfc.buf,
        &[_]pixelpkg.RGBA{.{ .r = 0, .g = 0, .b = 0, .a = 0 }} ** 200,
    );
}

test "ImageSurface, getPixel" {
    const sfc_T = ImageSurface(pixelpkg.RGBA);
    var sfc = try sfc_T.init(testing.allocator, 20, 10, null);
    defer sfc.deinit();

    {
        // OK
        const x: u32 = 7;
        const y: u32 = 5;
        const rgba: pixelpkg.RGBA = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC, .a = 0xDD };
        sfc.buf[y * 20 + x] = rgba;
        const expected_px: pixelpkg.Pixel = .{ .rgba = rgba };
        try testing.expectEqual(expected_px, sfc.getPixel(x, y));
    }

    {
        // Error, out of bounds
        try testing.expectError(error.ImageSurfaceGetPixelOutOfRange, sfc.getPixel(20, 9));
        try testing.expectError(error.ImageSurfaceGetPixelOutOfRange, sfc.getPixel(19, 10));
    }
}

test "ImageSurface, putPixel" {
    const sfc_T = ImageSurface(pixelpkg.RGBA);
    var sfc = try sfc_T.init(testing.allocator, 20, 10, null);
    defer sfc.deinit();

    const rgba: pixelpkg.RGBA = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC, .a = 0xDD };
    const pix_rgba = rgba.asPixel();

    {
        // OK
        const x: u32 = 7;
        const y: u32 = 5;
        try sfc.putPixel(x, y, pix_rgba);
        sfc.buf[y * 20 + x] = rgba;
        try testing.expectEqual(rgba, sfc.buf[y * 20 + x]);
    }

    {
        // Error, out of bounds
        try testing.expectError(error.ImageSurfacePutPixelOutOfRange, sfc.putPixel(20, 9, pix_rgba));
        try testing.expectError(error.ImageSurfacePutPixelOutOfRange, sfc.putPixel(19, 10, pix_rgba));
    }

    {
        // Error, incorrect pixel type
        const rgb: pixelpkg.RGB = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC };
        const pix_rgb = rgb.asPixel();
        try testing.expectError(error.InvalidPixelFormat, sfc.putPixel(1, 1, pix_rgb));
    }
}
