// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024 Chris Marchesi

//! Surfaces are rendering targets, such as pixel buffers of various formats.
//! Normally, you would use a `Context` to render to surfaces, but they can be
//! manipulated directly when needed.
//!
//! The buffer for each surface can be accessed directly through its union type
//! field (e.g., `sfc.image_surface_rgba.buf`) and `@bitcast` to get raw access
//! to its pixel data in the format specified (see the `pixel` module).

const mem = @import("std").mem;
const meta = @import("std").meta;
const testing = @import("std").testing;

const pixel = @import("pixel.zig");

/// The scale factor used for super-sample anti-aliasing. Any functionality
/// using the `downsample` method in a surface should be aware of this value.
pub const supersample_scale = 4;

/// Interface tags for surface types.
pub const SurfaceType = enum {
    image_surface_rgb,
    image_surface_rgba,
    image_surface_alpha8,

    fn toPixelType(self: SurfaceType) type {
        return switch (self) {
            .image_surface_rgb => pixel.RGB,
            .image_surface_rgba => pixel.RGBA,
            .image_surface_alpha8 => pixel.Alpha8,
        };
    }
};

/// Represents an interface as a union of the pixel formats. Any methods that
/// require an allocator must use the same allocator for the life of the
/// surface.
pub const Surface = union(SurfaceType) {
    image_surface_rgb: ImageSurface(pixel.RGB),
    image_surface_rgba: ImageSurface(pixel.RGBA),
    image_surface_alpha8: ImageSurface(pixel.Alpha8),

    /// Errors associated with surfaces.
    pub const Error = error{
        /// An invalid height was passed to surface initialization.
        InvalidHeight,

        /// An invalid width was passed to surface initialization.
        InvalidWidth,
    };

    /// Initializes a surface of the specific type. The surface buffer is
    /// initialized with the zero value for the pixel type (typically black or
    /// transparent).
    ///
    /// The caller owns the memory, so make sure to call deinit to release it.
    pub fn init(
        surface_type: SurfaceType,
        alloc: mem.Allocator,
        width: i32,
        height: i32,
    ) (Error || mem.Allocator.Error)!Surface {
        switch (surface_type) {
            inline else => |t| {
                const pt = t.toPixelType();
                return (try ImageSurface(pt).init(
                    alloc,
                    width,
                    height,
                    null,
                )).asSurfaceInterface();
            },
        }
    }

    /// Initializes a surface with the buffer set to the supplied pixel. The
    /// surface type is inferred from it.
    ///
    /// The caller owns the memory, so make sure to call deinit to release it.
    pub fn initPixel(
        initial_px: pixel.Pixel,
        alloc: mem.Allocator,
        width: i32,
        height: i32,
    ) (Error || mem.Allocator.Error)!Surface {
        switch (initial_px) {
            inline else => |px| {
                return (try ImageSurface(@TypeOf(px)).init(
                    alloc,
                    width,
                    height,
                    px,
                )).asSurfaceInterface();
            },
        }
    }

    /// Releases the underlying surface memory. The surface is invalid to use
    /// after calling this.
    pub fn deinit(self: *Surface, alloc: mem.Allocator) void {
        switch (self.*) {
            inline else => |*s| {
                s.deinit(alloc);
            },
        }
    }

    /// Downsamples the image, using simple pixel averaging.
    ///
    /// The surface is downsampled in-place. After downsampling, dimensions are
    /// altered and memory is freed.
    pub fn downsample(self: *Surface, alloc: mem.Allocator) void {
        switch (self.*) {
            inline else => |*s| s.downsample(alloc),
        }
    }

    /// Downsamples the image buffer, using simple pixel averaging.
    ///
    /// The surface is downsampled in-place. After downsampling, dimensions are
    /// altered. Memory must be freed from the underlying buffer manually if desired.
    pub fn downsampleBuffer(self: *Surface) void {
        switch (self.*) {
            inline else => |*s| s.downsampleBuffer(),
        }
    }

    /// Composites the source surface onto this surface using the Porter-Duff
    /// src-over operation at the destination. Any parts of the source outside
    /// of the destination are ignored.
    pub fn srcOver(dst: *Surface, src: *const Surface, dst_x: i32, dst_y: i32) void {
        return switch (dst.*) {
            inline else => |*s| s.srcOver(src, dst_x, dst_y),
        };
    }

    /// Composites the source surface onto this surface using the Porter-Duff
    /// dst-in operation at the destination. Any parts of the source outside
    /// of the destination are ignored.
    pub fn dstIn(dst: *Surface, src: *const Surface, dst_x: i32, dst_y: i32) void {
        return switch (dst.*) {
            inline else => |*s| s.dstIn(src, dst_x, dst_y),
        };
    }

    /// Gets the width of the surface.
    pub fn getWidth(self: Surface) i32 {
        return switch (self) {
            inline else => |s| s.width,
        };
    }

    /// Gets the height of the surface.
    pub fn getHeight(self: Surface) i32 {
        return switch (self) {
            inline else => |s| s.height,
        };
    }

    /// Gets the pixel format of the surface.
    pub fn getFormat(self: Surface) pixel.Format {
        return switch (self) {
            inline else => |s| @TypeOf(s).format,
        };
    }

    /// Gets the pixel data at the co-ordinates specified. Returns null if
    /// co-ordinates are out of range.
    pub fn getPixel(self: Surface, x: i32, y: i32) ?pixel.Pixel {
        return switch (self) {
            inline else => |s| s.getPixel(x, y),
        };
    }

    /// Puts a single pixel at the x and y co-ordinates. This is a no-op if the
    /// co-ordinates are out of range.
    pub fn putPixel(self: *Surface, x: i32, y: i32, px: pixel.Pixel) void {
        return switch (self.*) {
            inline else => |*s| s.putPixel(x, y, px),
        };
    }

    /// Replaces the surface with the supplied pixel.
    pub fn paintPixel(self: *Surface, px: pixel.Pixel) void {
        return switch (self.*) {
            inline else => |*s| s.paintPixel(px),
        };
    }
};

/// A memory-backed image surface. The pixel format is the type (e.g. RGB or
/// RGBA). Call init to return an initialized surface.
///
/// Any methods that take an allocator must use the same allocator for the
/// lifetime of the surface.
pub fn ImageSurface(comptime T: type) type {
    return struct {
        /// The width of the surface.
        width: i32,

        /// The height of the surface.
        height: i32,

        /// The underlying buffer. It's not advised to access this directly,
        /// rather use pixel operations such as getPixel and putPixel.
        ///
        /// The buffer is initialized to height * width on initialization,
        /// de-allocated on deinit, and is invalid to use after the latter is
        /// called.
        buf: []T,

        /// The format for the surface.
        pub const format: pixel.Format = T.format;

        /// Initializes a surface. deinit should be called when finished with
        /// the surface, which invalidates it, after which it should not be
        /// used. If non-null, the surface is initialized with the supplied
        /// pixel.
        pub fn init(
            alloc: mem.Allocator,
            width: i32,
            height: i32,
            initial_px_: ?T,
        ) (Surface.Error || mem.Allocator.Error)!ImageSurface(T) {
            if (width < 0) return error.InvalidWidth;
            if (height < 0) return error.InvalidHeight;

            const buf = try alloc.alloc(T, @intCast(height * width));
            return initBuffer(buf, width, height, initial_px_);
        }

        /// Initializes a surface with externally allocated memory. If you use
        /// this over init, do not use any method that takes an allocator as it
        /// will be an illegal operation.
        pub fn initBuffer(
            buf: []T,
            width: i32,
            height: i32,
            initial_px_: ?T,
        ) ImageSurface(T) {
            if (width < 0) @panic("invalid width");
            if (height < 0) @panic("invalid height");

            if (initial_px_) |initial_px| {
                @memset(buf, initial_px);
            } else {
                @memset(buf, mem.zeroes(T));
            }

            return .{
                .width = width,
                .height = height,
                .buf = buf,
            };
        }

        /// De-allocates the surface buffer. The surface is invalid for use after
        /// this is called.
        pub fn deinit(self: *ImageSurface(T), alloc: mem.Allocator) void {
            alloc.free(self.buf);
        }

        /// Downsamples the image, using simple pixel averaging.
        ///
        /// The surface is downsampled in-place. After downsampling, dimensions
        /// are altered and memory is freed.
        pub fn downsample(self: *ImageSurface(T), alloc: mem.Allocator) void {
            self.downsampleBuffer();
            self.resizeBuffer(alloc);
        }

        /// Downsamples a buffer in place. The caller is responsible for
        /// freeing the memory. After the downsample is complete, dimensions
        /// are updated.
        pub fn downsampleBuffer(self: *ImageSurface(T)) void {
            const scale = supersample_scale;
            const height: usize = @intCast(@divFloor(self.height, scale));
            const width: usize = @intCast(@divFloor(self.width, scale));

            for (0..@intCast(height)) |y| {
                for (0..@intCast(width)) |x| {
                    var pixels = [_]T{mem.zeroes(T)} ** (scale * scale);
                    for (0..scale) |i| {
                        for (0..scale) |j| {
                            const idx = (y * scale + i) * @as(usize, @intCast(self.width)) + (x * scale + j);
                            pixels[i * scale + j] = self.buf[idx];
                        }
                    }
                    self.buf[y * width + x] = T.average(&pixels);
                }
            }
            self.height = @intCast(height);
            self.width = @intCast(width);
        }

        /// Resizes the buffer to the dimensions set within the surface, if
        /// different.
        pub fn resizeBuffer(self: *ImageSurface(T), alloc: mem.Allocator) void {
            const height: usize = @intCast(self.height);
            const width: usize = @intCast(self.width);
            if (self.buf.len == height * width) return;
            if (alloc.resize(self.buf, height * width)) {
                self.buf = self.buf.ptr[0 .. height * width];
            }
        }

        /// Composites the source surface onto this surface using the
        /// Porter-Duff src-over operation at the destination. Any parts of the
        /// source outside of the destination are ignored.
        pub fn srcOver(
            dst: *ImageSurface(T),
            src: *const Surface,
            dst_x: i32,
            dst_y: i32,
        ) void {
            return dst.composite(src, T.srcOver, dst_x, dst_y);
        }

        /// Composites the source surface onto this surface using the
        /// Porter-Duff dst-in operation at the destination. Any parts of the
        /// source outside of the destination are ignored.
        pub fn dstIn(
            dst: *ImageSurface(T),
            src: *const Surface,
            dst_x: i32,
            dst_y: i32,
        ) void {
            return dst.composite(src, T.dstIn, dst_x, dst_y);
        }

        fn composite(
            dst: *ImageSurface(T),
            src: *const Surface,
            op: fn (T, pixel.Pixel) T,
            dst_x: i32,
            dst_y: i32,
        ) void {
            if (dst_x >= dst.width or dst_y >= dst.height) return;

            const src_start_y: i32 = if (dst_y < 0) @intCast(@abs(dst_y)) else 0;
            const src_start_x: i32 = if (dst_x < 0) @intCast(@abs(dst_x)) else 0;

            const height = if (src.getHeight() + dst_y > dst.height)
                dst.height - dst_y
            else
                src.getHeight();
            const width = if (src.getWidth() + dst_x > dst.width)
                dst.width - dst_x
            else
                src.getWidth();

            var src_y = src_start_y;
            while (src_y < height) : (src_y += 1) {
                var src_x = src_start_x;
                while (src_x < width) : (src_x += 1) {
                    const dst_put_x = src_x + dst_x;
                    const dst_put_y = src_y + dst_y;
                    const dst_idx: usize = @intCast(dst.width * dst_put_y + dst_put_x);
                    if (src.getPixel(@intCast(src_x), @intCast(src_y))) |src_px| {
                        const dst_px = dst.buf[dst_idx];
                        dst.buf[dst_idx] = op(dst_px, src_px);
                    }
                }
            }
        }

        /// Returns a Surface interface for this surface.
        pub fn asSurfaceInterface(self: ImageSurface(T)) Surface {
            return switch (T.format) {
                .rgba => .{ .image_surface_rgba = self },
                .rgb => .{ .image_surface_rgb = self },
                .alpha8 => .{ .image_surface_alpha8 = self },
            };
        }

        /// Gets the pixel data at the co-ordinates specified. Returns null if
        /// the co-ordinates are out of range.
        pub fn getPixel(self: *const ImageSurface(T), x: i32, y: i32) ?pixel.Pixel {
            if (x < 0 or y < 0 or x >= self.width or y >= self.height) return null;
            return self.buf[@intCast(self.width * y + x)].asPixel();
        }

        /// Puts a single pixel at the x and y co-ordinates. No-ops if the pixel is out of range.
        pub fn putPixel(self: *ImageSurface(T), x: i32, y: i32, px: pixel.Pixel) void {
            if (x < 0 or y < 0 or x >= self.width or y >= self.height) return;
            self.buf[@intCast(self.width * y + x)] = T.copySrc(px);
        }

        /// Replaces the surface with the supplied pixel.
        pub fn paintPixel(self: *ImageSurface(T), px: pixel.Pixel) void {
            @memset(self.buf, T.copySrc(px));
        }
    };
}

test "Surface interface" {
    {
        // RGB
        var sfc_if = try Surface.init(.image_surface_rgb, testing.allocator, 20, 10);
        defer sfc_if.deinit(testing.allocator);

        // getters
        try testing.expectEqual(20, sfc_if.getWidth());
        try testing.expectEqual(10, sfc_if.getHeight());
        try testing.expectEqual(.rgb, sfc_if.getFormat());

        // putPixel
        const rgb: pixel.RGB = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC };
        const pix_rgb = rgb.asPixel();
        const x: i32 = 7;
        const y: i32 = 5;

        sfc_if.putPixel(x, y, pix_rgb);

        // getPixel
        try testing.expectEqual(pix_rgb, sfc_if.getPixel(x, y));
    }

    {
        // RGBA
        var sfc_if = try Surface.init(.image_surface_rgba, testing.allocator, 20, 10);
        defer sfc_if.deinit(testing.allocator);

        // getters
        try testing.expectEqual(20, sfc_if.getWidth());
        try testing.expectEqual(10, sfc_if.getHeight());
        try testing.expectEqual(.rgba, sfc_if.getFormat());

        // putPixel
        const rgba: pixel.RGBA = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC, .a = 0xDD };
        const pix_rgba = rgba.asPixel();
        const x: i32 = 7;
        const y: i32 = 5;

        sfc_if.putPixel(x, y, pix_rgba);

        // getPixel
        try testing.expectEqual(pix_rgba, sfc_if.getPixel(x, y));
    }
}

test "ImageSurface, init, deinit" {
    const sfc_T = ImageSurface(pixel.RGBA);
    var sfc = try sfc_T.init(testing.allocator, 10, 20, null);
    defer sfc.deinit(testing.allocator);

    try testing.expectEqual(20, sfc.height);
    try testing.expectEqual(10, sfc.width);
    try testing.expectEqual(200, sfc.buf.len);
    try testing.expectEqual(meta.Elem(@TypeOf(sfc.buf)), pixel.RGBA);
    try testing.expectEqualSlices(
        pixel.RGBA,
        sfc.buf,
        &[_]pixel.RGBA{.{ .r = 0, .g = 0, .b = 0, .a = 0 }} ** 200,
    );
}

test "ImageSurface, getPixel" {
    const sfc_T = ImageSurface(pixel.RGBA);
    var sfc = try sfc_T.init(testing.allocator, 20, 10, null);
    defer sfc.deinit(testing.allocator);

    {
        // OK
        const x: i32 = 7;
        const y: i32 = 5;
        const rgba: pixel.RGBA = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC, .a = 0xDD };
        sfc.buf[y * 20 + x] = rgba;
        const expected_px: pixel.Pixel = .{ .rgba = rgba };
        try testing.expectEqual(expected_px, sfc.getPixel(x, y));
    }

    {
        // Out of bounds
        try testing.expectEqual(null, sfc.getPixel(20, 9));
        try testing.expectEqual(null, sfc.getPixel(19, 10));
    }
}

test "ImageSurface, putPixel" {
    const sfc_T = ImageSurface(pixel.RGBA);
    var sfc = try sfc_T.init(testing.allocator, 20, 10, null);
    defer sfc.deinit(testing.allocator);

    const rgba: pixel.RGBA = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC, .a = 0xDD };
    const pix_rgba = rgba.asPixel();

    {
        // OK
        const x: i32 = 7;
        const y: i32 = 5;
        sfc.putPixel(x, y, pix_rgba);
        sfc.buf[y * 20 + x] = rgba;
        try testing.expectEqual(rgba, sfc.buf[y * 20 + x]);
    }

    {
        // Error, out of bounds
        const orig = try testing.allocator.dupe(pixel.RGBA, sfc.buf);
        defer testing.allocator.free(orig);
        sfc.putPixel(20, 9, pix_rgba);
        try testing.expectEqualSlices(pixel.RGBA, orig, sfc.buf);
        sfc.putPixel(19, 10, pix_rgba);
        try testing.expectEqualSlices(pixel.RGBA, orig, sfc.buf);
    }

    {
        // Different pixel type (copySrc is used)
        const rgb: pixel.RGB = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC };
        const pix_rgb = rgb.asPixel();
        sfc.putPixel(1, 1, pix_rgb);
        try testing.expectEqual(
            pixel.RGBA{ .r = 0xAA, .g = 0xBB, .b = 0xCC, .a = 0xFF },
            sfc.buf[21],
        );
    }
}
