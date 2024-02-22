const mem = @import("std").mem;
const meta = @import("std").meta;
const testing = @import("std").testing;

const pixelpkg = @import("pixel.zig");

/// Interface tags for surface types.
pub const SurfaceType = enum {
    image_surface_rgb,
    image_surface_rgba,
};

/// Represents an interface as a union of the pixel formats.
pub const Surface = union(SurfaceType) {
    image_surface_rgb: *ImageSurface(pixelpkg.RGB),
    image_surface_rgba: *ImageSurface(pixelpkg.RGBA),

    /// Initializes a surface of the specific type.
    ///
    /// The caller owns the memory, so make sure to call deinit to release it.
    pub fn init(
        surface_type: SurfaceType,
        alloc: mem.Allocator,
        width: u32,
        height: u32,
    ) !Surface {
        switch (surface_type) {
            .image_surface_rgb => {
                const sfc = try alloc.create(ImageSurface(pixelpkg.RGB));
                errdefer alloc.destroy(sfc);
                sfc.* = try ImageSurface(pixelpkg.RGB).init(alloc, width, height);
                return sfc.asSurfaceInterface();
            },
            .image_surface_rgba => {
                const sfc = try alloc.create(ImageSurface(pixelpkg.RGBA));
                errdefer alloc.destroy(sfc);
                sfc.* = try ImageSurface(pixelpkg.RGBA).init(alloc, width, height);
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
            SurfaceType.image_surface_rgb => |s| {
                s.deinit();
                s.alloc.destroy(s);
            },
            SurfaceType.image_surface_rgba => |s| {
                s.deinit();
                s.alloc.destroy(s);
            },
        }
    }

    /// Gets the width of the surface.
    pub fn getWidth(self: Surface) u32 {
        return switch (self) {
            SurfaceType.image_surface_rgb => |s| s.width,
            SurfaceType.image_surface_rgba => |s| s.width,
        };
    }

    /// Gets the height of the surface.
    pub fn getHeight(self: Surface) u32 {
        return switch (self) {
            SurfaceType.image_surface_rgb => |s| s.height,
            SurfaceType.image_surface_rgba => |s| s.height,
        };
    }

    /// Gets the pixel format of the surface.
    pub fn getFormat(self: Surface) pixelpkg.Format {
        return switch (self) {
            SurfaceType.image_surface_rgb => |s| @TypeOf(s.*).format,
            SurfaceType.image_surface_rgba => |s| @TypeOf(s.*).format,
        };
    }

    /// Gets the pixel data at the co-ordinates specified.
    pub fn getPixel(self: Surface, x: u32, y: u32) !pixelpkg.Pixel {
        return switch (self) {
            SurfaceType.image_surface_rgb => |s| s.getPixel(x, y),
            SurfaceType.image_surface_rgba => |s| s.getPixel(x, y),
        };
    }

    /// Puts a single pixel at the x and y co-ordinates.
    pub fn putPixel(self: Surface, x: u32, y: u32, px: pixelpkg.Pixel) !void {
        return switch (self) {
            SurfaceType.image_surface_rgb => |s| s.putPixel(x, y, px),
            SurfaceType.image_surface_rgba => |s| s.putPixel(x, y, px),
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

        /// Initializes the surface. deinit should be called when finished with
        /// the surface, which invalidates it, after which it should not be
        /// used.
        pub fn init(alloc: mem.Allocator, width: u32, height: u32) !ImageSurface(T) {
            const buf = try alloc.alloc(T, height * width);
            @memset(buf, mem.zeroes(T));
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

        /// Returns a Surface interface for this surface.
        pub fn asSurfaceInterface(self: *ImageSurface(T)) Surface {
            return switch (T.format) {
                .rgba => .{ .image_surface_rgba = self },
                .rgb => .{ .image_surface_rgb = self },
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
    };
}

test "ImageSurface, init, deinit" {
    const sfc_T = ImageSurface(pixelpkg.RGBA);
    var sfc = try sfc_T.init(testing.allocator, 10, 20);
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
    var sfc = try sfc_T.init(testing.allocator, 20, 10);
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
    var sfc = try sfc_T.init(testing.allocator, 20, 10);
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
