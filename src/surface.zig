const std = @import("std");
const pixel = @import("pixel.zig");

/// Interface tags for surface types.
pub const SurfaceType = enum {
    image_surface_rgb,
    image_surface_rgba,
};

/// Represents an interface as a union of the pixel formats.
pub const Surface = union(SurfaceType) {
    image_surface_rgb: *ImageSurface(pixel.RGB),
    image_surface_rgba: *ImageSurface(pixel.RGBA),

    // Releases the underlying surface memory. The surface is invalid to use
    // after calling this.
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

    // Gets the width of the surface.
    pub fn width(self: Surface) u32 {
        return switch (self) {
            SurfaceType.image_surface_rgb => |s| s.width,
            SurfaceType.image_surface_rgba => |s| s.width,
        };
    }

    // Gets the height of the surface.
    pub fn height(self: Surface) u32 {
        return switch (self) {
            SurfaceType.image_surface_rgb => |s| s.height,
            SurfaceType.image_surface_rgba => |s| s.height,
        };
    }

    // Gets the pixel format of the surface.
    pub fn format(self: Surface) pixel.Format {
        return switch (self) {
            SurfaceType.image_surface_rgb => |s| @TypeOf(s.*).format,
            SurfaceType.image_surface_rgba => |s| @TypeOf(s.*).format,
        };
    }

    /// Gets the pixel data at the co-ordinates specified.
    pub fn getPixel(self: Surface, x: u32, y: u32) !pixel.Pixel {
        return switch (self) {
            SurfaceType.image_surface_rgb => |s| s.getPixel(x, y),
            SurfaceType.image_surface_rgba => |s| s.getPixel(x, y),
        };
    }

    /// Puts a single pixel at the x and y co-ordinates.
    pub fn putPixel(self: Surface, x: u32, y: u32, px: pixel.Pixel) !void {
        return switch (self) {
            SurfaceType.image_surface_rgb => |s| s.putPixel(x, y, px),
            SurfaceType.image_surface_rgba => |s| s.putPixel(x, y, px),
        };
    }
};

// Initializes a surface of the specific type.
pub fn createSurface(
    surface_type: SurfaceType,
    alloc: std.mem.Allocator,
    height: u32,
    width: u32,
) !Surface {
    switch (surface_type) {
        .image_surface_rgb => {
            const sfc = try alloc.create(ImageSurface(pixel.RGB));
            sfc.* = try ImageSurface(pixel.RGB).init(alloc, height, width);
            return sfc.asSurfaceInterface();
        },
        .image_surface_rgba => {
            const sfc = try alloc.create(ImageSurface(pixel.RGBA));
            sfc.* = try ImageSurface(pixel.RGBA).init(alloc, height, width);
            return sfc.asSurfaceInterface();
        },
    }
}

test "Surface interface" {
    {
        // RGB
        const sfc_if = try createSurface(.image_surface_rgb, std.testing.allocator, 10, 20);
        defer sfc_if.deinit();

        // getters
        try std.testing.expectEqual(20, sfc_if.width());
        try std.testing.expectEqual(10, sfc_if.height());
        try std.testing.expectEqual(.rgb, sfc_if.format());

        // putPixel
        const rgb: pixel.RGB = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC };
        const pix_rgb = rgb.asPixel();
        const x: u32 = 7;
        const y: u32 = 5;

        try sfc_if.putPixel(x, y, pix_rgb);

        // getPixel
        try std.testing.expectEqual(pix_rgb, sfc_if.getPixel(x, y));
    }

    {
        // RGBA
        const sfc_if = try createSurface(.image_surface_rgba, std.testing.allocator, 10, 20);
        defer sfc_if.deinit();

        // getters
        try std.testing.expectEqual(20, sfc_if.width());
        try std.testing.expectEqual(10, sfc_if.height());
        try std.testing.expectEqual(.rgba, sfc_if.format());

        // putPixel
        const rgba: pixel.RGBA = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC, .a = 0xDD };
        const pix_rgba = rgba.asPixel();
        const x: u32 = 7;
        const y: u32 = 5;

        try sfc_if.putPixel(x, y, pix_rgba);

        // getPixel
        try std.testing.expectEqual(pix_rgba, sfc_if.getPixel(x, y));
    }
}

/// A memory-backed image surface. The pixel format is the type (e.g. RGB or
/// RGBA). Call init to return an initialized surface.
fn ImageSurface(comptime T: type) type {
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

        /// The format for the surface.
        pub const format: pixel.Format = T.format;

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
        pub fn getPixel(self: *ImageSurface(T), x: u32, y: u32) !pixel.Pixel {
            // Check that data is in the surface range. If not, return an error.
            if (x >= self.width or y >= self.height) {
                return error.ImageSurfaceGetPixelOutOfRange;
            }

            return self.buf[self.width * y + x].asPixel();
        }

        /// Puts a single pixel at the x and y co-ordinates.
        pub fn putPixel(self: *ImageSurface(T), x: u32, y: u32, px: pixel.Pixel) !void {
            // Check that data is in the surface range. If not, return an error.
            if (x >= self.width or y >= self.height) {
                return error.ImageSurfacePutPixelOutOfRange;
            }
            self.buf[self.width * y + x] = try T.fromPixel(px);
        }
    };
}

test "ImageSurface, init, deinit" {
    const sfc_T = ImageSurface(pixel.RGBA);
    var sfc = try sfc_T.init(std.testing.allocator, 10, 20);
    defer sfc.deinit();

    try std.testing.expectEqual(10, sfc.height);
    try std.testing.expectEqual(20, sfc.width);
    try std.testing.expectEqual(200, sfc.buf.len);
    try std.testing.expectEqual(std.meta.Elem(@TypeOf(sfc.buf)), pixel.RGBA);
    try std.testing.expectEqualSlices(
        pixel.RGBA,
        sfc.buf,
        &[_]pixel.RGBA{.{ .r = 0, .g = 0, .b = 0, .a = 0 }} ** 200,
    );
}

test "ImageSurface, getPixel" {
    const sfc_T = ImageSurface(pixel.RGBA);
    var sfc = try sfc_T.init(std.testing.allocator, 10, 20);
    defer sfc.deinit();

    {
        // OK
        const x: u32 = 7;
        const y: u32 = 5;
        const rgba: pixel.RGBA = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC, .a = 0xDD };
        sfc.buf[y * 20 + x] = rgba;
        const expected_px: pixel.Pixel = .{ .rgba = rgba };
        try std.testing.expectEqual(expected_px, sfc.getPixel(x, y));
    }

    {
        // Error, out of bounds
        try std.testing.expectError(error.ImageSurfaceGetPixelOutOfRange, sfc.getPixel(20, 9));
        try std.testing.expectError(error.ImageSurfaceGetPixelOutOfRange, sfc.getPixel(19, 10));
    }
}

test "ImageSurface, putPixel" {
    const sfc_T = ImageSurface(pixel.RGBA);
    var sfc = try sfc_T.init(std.testing.allocator, 10, 20);
    defer sfc.deinit();

    const rgba: pixel.RGBA = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC, .a = 0xDD };
    const pix_rgba = rgba.asPixel();

    {
        // OK
        const x: u32 = 7;
        const y: u32 = 5;
        try sfc.putPixel(x, y, pix_rgba);
        sfc.buf[y * 20 + x] = rgba;
        try std.testing.expectEqual(rgba, sfc.buf[y * 20 + x]);
    }

    {
        // Error, out of bounds
        try std.testing.expectError(error.ImageSurfacePutPixelOutOfRange, sfc.putPixel(20, 9, pix_rgba));
        try std.testing.expectError(error.ImageSurfacePutPixelOutOfRange, sfc.putPixel(19, 10, pix_rgba));
    }

    {
        // Error, incorrect pixel type
        const rgb: pixel.RGB = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC };
        const pix_rgb = rgb.asPixel();
        try std.testing.expectError(error.InvalidPixelFormat, sfc.putPixel(1, 1, pix_rgb));
    }
}
