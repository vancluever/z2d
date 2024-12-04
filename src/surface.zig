// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024 Chris Marchesi

//! Surfaces are rendering targets, such as pixel buffers of various formats.
//! Normally, you would use a `Context` (or the unmanaged `painter` package) to
//! render to surfaces, but they can be manipulated directly when needed.
//!
//! The buffer for each surface can be accessed directly through its union type
//! field (e.g., `sfc.image_surface_rgba.buf`) and `@bitCast` to get raw access
//! to its pixel data in the format specified (see the `pixel` module).
//!
//! For packed-buffer surfaces (those backed by `PackedImageSurface` with pixel
//! widths smaller than 8 bits), there are some considerations for interpreting
//! the raw `[]u8` that the buffer is stored as. See the type function for more
//! details.

const std = @import("std");
const heap = @import("std").heap;
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
    image_surface_alpha4,
    image_surface_alpha2,
    image_surface_alpha1,

    pub fn toPixelType(self: SurfaceType) type {
        return switch (self) {
            .image_surface_rgb => pixel.RGB,
            .image_surface_rgba => pixel.RGBA,
            .image_surface_alpha8 => pixel.Alpha8,
            .image_surface_alpha4 => pixel.Alpha4,
            .image_surface_alpha2 => pixel.Alpha2,
            .image_surface_alpha1 => pixel.Alpha1,
        };
    }

    fn toBufferType(self: SurfaceType) type {
        return switch (self) {
            .image_surface_rgb => pixel.RGB,
            .image_surface_rgba => pixel.RGBA,
            .image_surface_alpha8 => pixel.Alpha8,
            .image_surface_alpha4 => u8,
            .image_surface_alpha2 => u8,
            .image_surface_alpha1 => u8,
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
    image_surface_alpha4: PackedImageSurface(pixel.Alpha4),
    image_surface_alpha2: PackedImageSurface(pixel.Alpha2),
    image_surface_alpha1: PackedImageSurface(pixel.Alpha1),

    /// Errors associated with surfaces.
    pub const Error = error{
        /// An invalid height was passed to surface initialization.
        InvalidHeight,

        /// An invalid width was passed to surface initialization.
        InvalidWidth,
    };

    /// Initializes a surface of the specific `surface_type`. The surface
    /// buffer is initialized with the zero value for the pixel type (typically
    /// black or transparent). The caller owns the memory, so make sure to call
    /// `deinit` to release it.
    pub fn init(
        surface_type: SurfaceType,
        alloc: mem.Allocator,
        width: i32,
        height: i32,
    ) (Error || mem.Allocator.Error)!Surface {
        switch (surface_type) {
            inline .image_surface_alpha4, .image_surface_alpha2, .image_surface_alpha1 => |t| {
                const pt = t.toPixelType();
                return (try PackedImageSurface(pt).init(
                    alloc,
                    width,
                    height,
                    null,
                )).asSurfaceInterface();
            },
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

    /// Initializes a surface with the buffer set to the supplied `initial_px`.
    /// The surface type is inferred from it. The caller owns the memory, so
    /// make sure to call `deinit` to release it.
    pub fn initPixel(
        initial_px: pixel.Pixel,
        alloc: mem.Allocator,
        width: i32,
        height: i32,
    ) (Error || mem.Allocator.Error)!Surface {
        switch (initial_px) {
            inline .alpha4, .alpha2, .alpha1 => |px| {
                return (try PackedImageSurface(@TypeOf(px)).init(
                    alloc,
                    width,
                    height,
                    px,
                )).asSurfaceInterface();
            },
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

    /// Initializes a surface with externally allocated memory. The buffer is
    /// initialized with `initial_px_` or the zero value (opaque or transparent
    /// black) if it is `null`. If you use this over `init` or `initPixel`, do
    /// not use any method that takes an allocator as it will be an illegal
    /// operation.
    pub fn initBuffer(
        comptime surface_type: SurfaceType,
        initial_px_: ?surface_type.toPixelType(),
        buf: []surface_type.toBufferType(),
        width: i32,
        height: i32,
    ) Surface {
        switch (surface_type) {
            .image_surface_alpha4, .image_surface_alpha2, .image_surface_alpha1 => |t| {
                return PackedImageSurface(t.toPixelType()).initBuffer(
                    buf,
                    width,
                    height,
                    initial_px_,
                ).asSurfaceInterface();
            },
            else => |t| {
                return ImageSurface(t.toPixelType()).initBuffer(
                    buf,
                    width,
                    height,
                    initial_px_,
                ).asSurfaceInterface();
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

    /// Downsamples the image, using simple pixel averaging. The surface is
    /// downsampled in-place. After downsampling, dimensions are altered and
    /// memory is freed.
    pub fn downsample(self: *Surface, alloc: mem.Allocator) void {
        switch (self.*) {
            inline else => |*s| s.downsample(alloc),
        }
    }

    /// Downsamples the image buffer, using simple pixel averaging. The surface
    /// is downsampled in-place. After downsampling, dimensions are altered.
    /// Memory must be freed from the underlying buffer manually if desired.
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

    /// Gets the pixel data at the co-ordinates specified. Returns `null` if
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

/// A memory-backed image surface. The pixel format is the type (e.g.
/// `Pixel.RGB` or `Pixel.RGBA`). Call `init` or `initBuffer` to return an
/// initialized surface.
///
/// Any methods that take an allocator must use the same allocator for the
/// lifetime of the surface.
pub fn ImageSurface(comptime T: type) type {
    return struct {
        /// The width of the surface.
        width: i32,

        /// The height of the surface.
        height: i32,

        /// The underlying buffer. Check the top-level package documentation
        /// for details on how to interpret the buffer.
        ///
        /// The buffer is initialized to `width` * `height` on initialization,
        /// de-allocated on `deinit`, and is invalid to use after the latter is
        /// called.
        buf: []T,

        /// The format for the surface.
        pub const format: pixel.Format = T.format;

        /// Initializes a surface. `deinit` should be called when finished with
        /// the surface, which invalidates it, after which it should not be
        /// used. If non-null, the surface is initialized with the supplied
        /// `initial_px_`.
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
        /// this over `init`, do not use any method that takes an allocator as it
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

        /// Downsamples the image, using simple pixel averaging. The surface is
        /// downsampled in-place. After downsampling, dimensions are altered
        /// and memory is freed.
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

        /// Returns a `Surface` interface for this surface.
        pub fn asSurfaceInterface(self: ImageSurface(T)) Surface {
            return switch (T.format) {
                .rgba => .{ .image_surface_rgba = self },
                .rgb => .{ .image_surface_rgb = self },
                .alpha8 => .{ .image_surface_alpha8 = self },
                else => unreachable,
            };
        }

        /// Gets the pixel data at the co-ordinates specified. Returns `null`
        /// if the co-ordinates are out of range.
        pub fn getPixel(self: *const ImageSurface(T), x: i32, y: i32) ?pixel.Pixel {
            if (x < 0 or y < 0 or x >= self.width or y >= self.height) return null;
            return self.buf[@intCast(self.width * y + x)].asPixel();
        }

        /// Puts a single pixel at the `x` and `y` co-ordinates. No-ops if the
        /// pixel is out of range.
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

/// A specialized surface for pixel types that are smaller than 8 bits in size,
/// packing the data into a `PackedIntSlice` in little-endian fashion.
///
/// ## Accessing pixel data
///
/// The buffer is stored in the standard location (e.g., from the `Pixel`
/// interface, through something like `sfc.image_surface_alpha1.buf`) but as a
/// `[]u8` as opposed to `[]T`. Data is stored in little-endian fashion,
/// consistent with the layout of our packed pixel structs.
///
/// As an example, for a 8x2 Alpha1 surface, our first row would be stored in
/// `buf[0]` and the second row would be stored in `buf[1]`, with the lowest
/// row index for each being in the LSB (i.e., x=0,y=0 being in mask=0x1 in
/// `buf[0]`, and x=0,y=1 being in mask=0x1 in `buf[1]`).
pub fn PackedImageSurface(comptime T: type) type {
    // Comptime assert that we only allow 1, 2, and 4 bit sizes in this struct.
    comptime std.debug.assert(@bitSizeOf(T) < 8 and 8 % @bitSizeOf(T) == 0);

    return struct {
        /// The width of the surface.
        width: i32,

        /// The height of the surface.
        height: i32,

        /// The underlying buffer as a densely-packed []u8. See the type
        /// function documentation for details on how to interpret the buffer.
        buf: []u8,

        /// The PackedIntSlice interface to buf, through which most of the
        /// surface interacts.
        buf_packed_if: std.PackedIntSliceEndian(T, .little),

        /// The format for the surface.
        pub const format: pixel.Format = T.format;

        /// Initializes a surface. `deinit` should be called when finished with
        /// the surface, which invalidates it, after which it should not be
        /// used. If non-null, the surface is initialized with the supplied
        /// `initial_px_`.
        pub fn init(
            alloc: mem.Allocator,
            width: i32,
            height: i32,
            initial_px_: ?T,
        ) (Surface.Error || mem.Allocator.Error)!PackedImageSurface(T) {
            if (width < 0) return error.InvalidWidth;
            if (height < 0) return error.InvalidHeight;

            const h_usize: usize = @intCast(height);
            const w_usize: usize = @intCast(width);
            const len = (h_usize * w_usize * @bitSizeOf(T) + 7) / 8;
            const buf = try alloc.alloc(u8, len);
            return initBuffer(buf, width, height, initial_px_);
        }

        /// Initializes a surface with externally allocated memory. If you use
        /// this over `init`, do not use any method that takes an allocator as it
        /// will be an illegal operation.
        pub fn initBuffer(
            buf: []u8,
            width: i32,
            height: i32,
            initial_px_: ?T,
        ) PackedImageSurface(T) {
            if (width < 0) @panic("invalid width");
            if (height < 0) @panic("invalid height");

            if (initial_px_) |initial_px| {
                _paintPixel(buf, initial_px);
            } else {
                @memset(buf, 0);
            }

            return .{
                .width = width,
                .height = height,
                .buf = buf,
                .buf_packed_if = std.PackedIntSliceEndian(T, .little).init(buf, @intCast(height * width)),
            };
        }

        /// De-allocates the surface buffer. The surface is invalid for use after
        /// this is called.
        pub fn deinit(self: *PackedImageSurface(T), alloc: mem.Allocator) void {
            alloc.free(self.buf);
        }

        /// Downsamples the image, using simple pixel averaging. The surface is
        /// downsampled in-place. After downsampling, dimensions are altered
        /// and memory is freed.
        pub fn downsample(self: *PackedImageSurface(T), alloc: mem.Allocator) void {
            self.downsampleBuffer();
            self.resizeBuffer(alloc);
        }

        /// Downsamples a buffer in place. The caller is responsible for
        /// freeing the memory. After the downsample is complete, dimensions
        /// are updated.
        pub fn downsampleBuffer(self: *PackedImageSurface(T)) void {
            const scale = supersample_scale;
            const height: usize = @intCast(@divFloor(self.height, scale));
            const width: usize = @intCast(@divFloor(self.width, scale));

            for (0..@intCast(height)) |y| {
                for (0..@intCast(width)) |x| {
                    var pixels = [_]T{mem.zeroes(T)} ** (scale * scale);
                    for (0..scale) |i| {
                        for (0..scale) |j| {
                            const idx = (y * scale + i) * @as(usize, @intCast(self.width)) + (x * scale + j);
                            pixels[i * scale + j] = self.buf_packed_if.get(idx);
                        }
                    }
                    self.buf_packed_if.set(y * width + x, T.average(&pixels));
                }
            }
            self.height = @intCast(height);
            self.width = @intCast(width);
        }

        /// Resizes the buffer to the dimensions set within the surface, if
        /// different.
        pub fn resizeBuffer(self: *PackedImageSurface(T), alloc: mem.Allocator) void {
            const height: usize = @intCast(self.height);
            const width: usize = @intCast(self.width);
            const new_len: usize = (height * width * @bitSizeOf(T) + 7) / 8;
            if (self.buf.len == new_len) return;
            if (alloc.resize(self.buf, new_len)) {
                self.buf = self.buf.ptr[0..new_len];
                self.buf_packed_if = self.buf_packed_if.slice(0, height * width);
            }
        }

        /// Composites the source surface onto this surface using the
        /// Porter-Duff src-over operation at the destination. Any parts of the
        /// source outside of the destination are ignored.
        pub fn srcOver(
            dst: *PackedImageSurface(T),
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
            dst: *PackedImageSurface(T),
            src: *const Surface,
            dst_x: i32,
            dst_y: i32,
        ) void {
            return dst.composite(src, T.dstIn, dst_x, dst_y);
        }

        fn composite(
            dst: *PackedImageSurface(T),
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
                        const dst_px = dst.buf_packed_if.get(dst_idx);
                        dst.buf_packed_if.set(dst_idx, op(dst_px, src_px));
                    }
                }
            }
        }

        /// Returns a `Surface` interface for this surface.
        pub fn asSurfaceInterface(self: PackedImageSurface(T)) Surface {
            return switch (T.format) {
                .alpha4 => .{ .image_surface_alpha4 = self },
                .alpha2 => .{ .image_surface_alpha2 = self },
                .alpha1 => .{ .image_surface_alpha1 = self },
                else => unreachable,
            };
        }

        /// Gets the pixel data at the co-ordinates specified. Returns `null`
        /// if the co-ordinates are out of range.
        pub fn getPixel(self: *const PackedImageSurface(T), x: i32, y: i32) ?pixel.Pixel {
            if (x < 0 or y < 0 or x >= self.width or y >= self.height) return null;
            return self.buf_packed_if.get(@intCast(self.width * y + x)).asPixel();
        }

        /// Puts a single pixel at the `x` and `y` co-ordinates. No-ops if the
        /// pixel is out of range.
        pub fn putPixel(self: *PackedImageSurface(T), x: i32, y: i32, px: pixel.Pixel) void {
            if (x < 0 or y < 0 or x >= self.width or y >= self.height) return;
            self.buf_packed_if.set(@intCast(self.width * y + x), T.copySrc(px));
        }

        /// Replaces the surface with the supplied pixel.
        pub fn paintPixel(self: *PackedImageSurface(T), px: pixel.Pixel) void {
            _paintPixel(self.buf, T.copySrc(px));
        }

        fn _paintPixel(buf: []u8, px: T) void {
            // There's nothing like setAll in packed_int_array unfortunately,
            // so we roll our own, albeit tailored to our specific purpose, by
            // basically taking the pixel that we are supposed to set and using
            // that to pack a u8 with the number of pixels that will fit, then
            // just using that to memset the slice. Note that this may fill
            // past the end of the canvas into the excess in the last byte, but
            // that's fine as this space is undefined in our implementation
            // anyway.
            //
            // NOTE: This pattern *should* be resilient across endianness.
            // We're not doing any math here, and if intCast from a smaller
            // bit width to a larger one respects endianness, it should just
            // throw it in the correct location (least or most significant
            // portion) in memory, which won't matter when it comes back into
            // the CPU for bit shifting. After shifting/copying is complete, we
            // will end up with even copies of the smaller-width integer since
            // we fill the whole byte, so the order of where it ends up in the
            // intCast should not matter.
            if (meta.eql(px, std.mem.zeroes(T))) {
                // Short-circuit to writing zeroes if the pixel we're setting is zero
                @memset(buf, 0);
                return;
            }

            const px_u8: u8 = px_u8: {
                const px_int_t = @typeInfo(T).Struct.backing_integer.?;
                const px_int = @as(px_int_t, @bitCast(px));
                break :px_u8 @intCast(px_int);
            };
            var packed_px: u8 = 0;
            var sh: usize = 0;
            while (sh <= 8 - @bitSizeOf(T)) : (sh += @bitSizeOf(T)) {
                packed_px |= px_u8 << @intCast(sh);
            }

            @memset(buf, packed_px);
        }
    };
}

test "Surface interface" {
    {
        // Base RGBA, we just cast this to all of our other types via copySrc
        const rgba: pixel.RGBA = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC, .a = 0xDD };

        // Standard tests
        inline for (@typeInfo(SurfaceType).Enum.fields) |f| {
            const surface_type: SurfaceType = @enumFromInt(f.value);
            const pixel_type = surface_type.toPixelType();
            const pix = pixel_type.copySrc(rgba.asPixel()).asPixel();

            var sfc_if = try Surface.init(surface_type, testing.allocator, 1, 1);
            defer sfc_if.deinit(testing.allocator);

            // getters
            try testing.expectEqual(1, sfc_if.getWidth());
            try testing.expectEqual(1, sfc_if.getHeight());
            try testing.expectEqual(pixel_type.format, sfc_if.getFormat());

            // setters
            sfc_if.putPixel(0, 0, pix);

            // getPixel
            try testing.expectEqual(pix, sfc_if.getPixel(0, 0));
        }

        // initPixel tests
        inline for (@typeInfo(SurfaceType).Enum.fields) |f| {
            const surface_type: SurfaceType = @enumFromInt(f.value);
            const pixel_type = surface_type.toPixelType();
            const pix = pixel_type.copySrc(rgba.asPixel()).asPixel();

            var sfc_if = try Surface.initPixel(pix, testing.allocator, 1, 1);
            defer sfc_if.deinit(testing.allocator);

            // getters
            try testing.expectEqual(1, sfc_if.getWidth());
            try testing.expectEqual(1, sfc_if.getHeight());
            try testing.expectEqual(pixel_type.format, sfc_if.getFormat());

            // getPixel
            try testing.expectEqual(pix, sfc_if.getPixel(0, 0));
        }

        // Bring-your-own-buffer tests
        inline for (@typeInfo(SurfaceType).Enum.fields) |f| {
            const surface_type: SurfaceType = @enumFromInt(f.value);
            const pixel_type = surface_type.toPixelType();
            const buffer_type = surface_type.toBufferType();
            const pix = pixel_type.copySrc(rgba.asPixel()).asPixel();

            var buf: [1]buffer_type = undefined;
            var sfc_if = Surface.initBuffer(surface_type, null, &buf, 1, 1);

            // getters
            try testing.expectEqual(1, sfc_if.getWidth());
            try testing.expectEqual(1, sfc_if.getHeight());
            try testing.expectEqual(pixel_type.format, sfc_if.getFormat());

            // setters
            sfc_if.putPixel(0, 0, pix);

            // getPixel
            try testing.expectEqual(pix, sfc_if.getPixel(0, 0));
        }
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

test "PackedImageSurface, alpha4" {
    {
        // basic layout test, 3x3, puts pixels in the following layout:
        //
        // 5  0  0
        // 0  10 0
        // 0  0  15
        //
        // In this instance, we expect [5]u8 as the buffer, with the
        // appropriate bits set, endian defined. Our padding (last 6 bits in
        // the last byte) is all zeroes.
        var sfc = try PackedImageSurface(pixel.Alpha4).init(testing.allocator, 3, 3, null);
        defer sfc.deinit(testing.allocator);
        sfc.putPixel(0, 0, .{ .alpha4 = .{ .a = 5 } });
        sfc.putPixel(1, 1, .{ .alpha4 = .{ .a = 10 } });
        sfc.putPixel(2, 2, .{ .alpha4 = .{ .a = 15 } });

        try testing.expectEqual(5, sfc.buf.len);
        try testing.expectEqual(5, sfc.buf[0]);
        try testing.expectEqual(0, sfc.buf[1]);
        try testing.expectEqual(10, sfc.buf[2]);
        try testing.expectEqual(0, sfc.buf[3]);
        try testing.expectEqual(15, sfc.buf[4]);
        try testing.expectEqual(pixel.Pixel{ .alpha4 = .{ .a = 5 } }, sfc.getPixel(0, 0));
        try testing.expectEqual(pixel.Pixel{ .alpha4 = .{ .a = 0 } }, sfc.getPixel(1, 0));
        try testing.expectEqual(pixel.Pixel{ .alpha4 = .{ .a = 0 } }, sfc.getPixel(2, 0));
        try testing.expectEqual(pixel.Pixel{ .alpha4 = .{ .a = 0 } }, sfc.getPixel(0, 1));
        try testing.expectEqual(pixel.Pixel{ .alpha4 = .{ .a = 10 } }, sfc.getPixel(1, 1));
        try testing.expectEqual(pixel.Pixel{ .alpha4 = .{ .a = 0 } }, sfc.getPixel(2, 1));
        try testing.expectEqual(pixel.Pixel{ .alpha4 = .{ .a = 0 } }, sfc.getPixel(0, 2));
        try testing.expectEqual(pixel.Pixel{ .alpha4 = .{ .a = 0 } }, sfc.getPixel(1, 2));
        try testing.expectEqual(pixel.Pixel{ .alpha4 = .{ .a = 15 } }, sfc.getPixel(2, 2));
        try testing.expectEqual(null, sfc.getPixel(0, 3));
    }

    {
        // Initial pixel initialization. We expect this to fill the whole 3
        // bytes in the buffer even though the buffer is supposed to only be 18
        // bits (bounds checks are a product of HxW on part of the consumer).
        var sfc = try PackedImageSurface(pixel.Alpha4).init(
            testing.allocator,
            3,
            3,
            .{ .a = 15 },
        );
        defer sfc.deinit(testing.allocator);

        try testing.expectEqual(5, sfc.buf.len);
        try testing.expectEqual(0xFF, sfc.buf[0]);
        try testing.expectEqual(0xFF, sfc.buf[1]);
        try testing.expectEqual(0xFF, sfc.buf[2]);
        try testing.expectEqual(0xFF, sfc.buf[3]);
        try testing.expectEqual(0xFF, sfc.buf[4]);
    }

    {
        // Downsampling
        var sfc = try PackedImageSurface(pixel.Alpha4).init(testing.allocator, 4, 4, null);
        defer sfc.deinit(testing.allocator);
        sfc.putPixel(0, 0, .{ .alpha4 = .{ .a = 15 } });
        sfc.putPixel(0, 1, .{ .alpha4 = .{ .a = 15 } });
        sfc.putPixel(0, 2, .{ .alpha4 = .{ .a = 15 } });
        sfc.putPixel(0, 3, .{ .alpha4 = .{ .a = 15 } });
        sfc.putPixel(1, 0, .{ .alpha4 = .{ .a = 15 } });
        sfc.putPixel(1, 1, .{ .alpha4 = .{ .a = 15 } });
        sfc.putPixel(1, 2, .{ .alpha4 = .{ .a = 15 } });
        sfc.putPixel(1, 3, .{ .alpha4 = .{ .a = 15 } });

        sfc.downsample(testing.allocator);

        try testing.expectEqual(1, sfc.buf.len);
        try testing.expectEqual(1, sfc.width);
        try testing.expectEqual(1, sfc.height);
        try testing.expectEqual(pixel.Pixel{ .alpha4 = .{ .a = 7 } }, sfc.getPixel(0, 0));
    }
}

test "PackedImageSurface, alpha2" {
    {
        // basic layout test, 3x3, puts pixels in the following layout:
        //
        // 1 0 0
        // 0 2 0
        // 0 0 3
        //
        // In this instance, we expect [3]u8 as the buffer, with the
        // appropriate bits set, endian defined. Our padding (last 6 bits in
        // the last byte) is all zeroes.
        var sfc = try PackedImageSurface(pixel.Alpha2).init(testing.allocator, 3, 3, null);
        defer sfc.deinit(testing.allocator);
        sfc.putPixel(0, 0, .{ .alpha2 = .{ .a = 1 } });
        sfc.putPixel(1, 1, .{ .alpha2 = .{ .a = 2 } });
        sfc.putPixel(2, 2, .{ .alpha2 = .{ .a = 3 } });

        try testing.expectEqual(3, sfc.buf.len);
        try testing.expectEqual(1, sfc.buf[0]);
        try testing.expectEqual(2, sfc.buf[1]);
        try testing.expectEqual(3, sfc.buf[2]);
        try testing.expectEqual(pixel.Pixel{ .alpha2 = .{ .a = 1 } }, sfc.getPixel(0, 0));
        try testing.expectEqual(pixel.Pixel{ .alpha2 = .{ .a = 0 } }, sfc.getPixel(1, 0));
        try testing.expectEqual(pixel.Pixel{ .alpha2 = .{ .a = 0 } }, sfc.getPixel(2, 0));
        try testing.expectEqual(pixel.Pixel{ .alpha2 = .{ .a = 0 } }, sfc.getPixel(0, 1));
        try testing.expectEqual(pixel.Pixel{ .alpha2 = .{ .a = 2 } }, sfc.getPixel(1, 1));
        try testing.expectEqual(pixel.Pixel{ .alpha2 = .{ .a = 0 } }, sfc.getPixel(2, 1));
        try testing.expectEqual(pixel.Pixel{ .alpha2 = .{ .a = 0 } }, sfc.getPixel(0, 2));
        try testing.expectEqual(pixel.Pixel{ .alpha2 = .{ .a = 0 } }, sfc.getPixel(1, 2));
        try testing.expectEqual(pixel.Pixel{ .alpha2 = .{ .a = 3 } }, sfc.getPixel(2, 2));
        try testing.expectEqual(null, sfc.getPixel(0, 3));
    }

    {
        // Initial pixel initialization. We expect this to fill the whole 3
        // bytes in the buffer even though the buffer is supposed to only be 18
        // bits (bounds checks are a product of HxW on part of the consumer).
        var sfc = try PackedImageSurface(pixel.Alpha2).init(
            testing.allocator,
            3,
            3,
            .{ .a = 3 },
        );
        defer sfc.deinit(testing.allocator);

        try testing.expectEqual(3, sfc.buf.len);
        try testing.expectEqual(0xFF, sfc.buf[0]);
        try testing.expectEqual(0xFF, sfc.buf[1]);
        try testing.expectEqual(0xFF, sfc.buf[2]);
    }

    {
        // Downsampling
        var sfc = try PackedImageSurface(pixel.Alpha2).init(testing.allocator, 4, 4, null);
        defer sfc.deinit(testing.allocator);
        sfc.putPixel(0, 0, .{ .alpha2 = .{ .a = 3 } });
        sfc.putPixel(0, 1, .{ .alpha2 = .{ .a = 3 } });
        sfc.putPixel(0, 2, .{ .alpha2 = .{ .a = 3 } });
        sfc.putPixel(0, 3, .{ .alpha2 = .{ .a = 3 } });
        sfc.putPixel(1, 0, .{ .alpha2 = .{ .a = 3 } });
        sfc.putPixel(1, 1, .{ .alpha2 = .{ .a = 3 } });
        sfc.putPixel(1, 2, .{ .alpha2 = .{ .a = 3 } });
        sfc.putPixel(1, 3, .{ .alpha2 = .{ .a = 3 } });
        sfc.putPixel(2, 0, .{ .alpha2 = .{ .a = 3 } });
        sfc.putPixel(2, 1, .{ .alpha2 = .{ .a = 3 } });
        sfc.putPixel(2, 2, .{ .alpha2 = .{ .a = 3 } });

        sfc.downsample(testing.allocator);

        try testing.expectEqual(1, sfc.buf.len);
        try testing.expectEqual(1, sfc.width);
        try testing.expectEqual(1, sfc.height);
        try testing.expectEqual(pixel.Pixel{ .alpha2 = .{ .a = 2 } }, sfc.getPixel(0, 0));
    }
}

test "PackedImageSurface, alpha1" {
    {
        // basic layout test, 3x3, puts pixels in the following layout:
        //
        // 1 0 0
        // 0 1 0
        // 0 0 1
        //
        // In this instance, we expect [2]u8 as the buffer, with the
        // appropriate bits set in the first index, and 1 in the LSB
        // (endian-dependent) in the second index, with the rest being zeroes.
        var sfc = try PackedImageSurface(pixel.Alpha1).init(testing.allocator, 3, 3, null);
        defer sfc.deinit(testing.allocator);
        sfc.putPixel(0, 0, .{ .alpha1 = .{ .a = 1 } });
        sfc.putPixel(1, 1, .{ .alpha1 = .{ .a = 1 } });
        sfc.putPixel(2, 2, .{ .alpha1 = .{ .a = 1 } });

        try testing.expectEqual(2, sfc.buf.len);
        try testing.expectEqual(0b10001, sfc.buf[0]);
        try testing.expectEqual(1, sfc.buf[1]);
        try testing.expectEqual(pixel.Pixel{ .alpha1 = .{ .a = 1 } }, sfc.getPixel(0, 0));
        try testing.expectEqual(pixel.Pixel{ .alpha1 = .{ .a = 0 } }, sfc.getPixel(1, 0));
        try testing.expectEqual(pixel.Pixel{ .alpha1 = .{ .a = 0 } }, sfc.getPixel(2, 0));
        try testing.expectEqual(pixel.Pixel{ .alpha1 = .{ .a = 0 } }, sfc.getPixel(0, 1));
        try testing.expectEqual(pixel.Pixel{ .alpha1 = .{ .a = 1 } }, sfc.getPixel(1, 1));
        try testing.expectEqual(pixel.Pixel{ .alpha1 = .{ .a = 0 } }, sfc.getPixel(2, 1));
        try testing.expectEqual(pixel.Pixel{ .alpha1 = .{ .a = 0 } }, sfc.getPixel(0, 2));
        try testing.expectEqual(pixel.Pixel{ .alpha1 = .{ .a = 0 } }, sfc.getPixel(1, 2));
        try testing.expectEqual(pixel.Pixel{ .alpha1 = .{ .a = 1 } }, sfc.getPixel(2, 2));
        try testing.expectEqual(null, sfc.getPixel(0, 3));
    }

    {
        // Initial pixel initialization. We expect this to fill the whole 2
        // bytes in the buffer even though the buffer is supposed to only be 9
        // bits (bounds checks are a product of HxW on part of the consumer).
        var sfc = try PackedImageSurface(pixel.Alpha1).init(
            testing.allocator,
            3,
            3,
            .{ .a = 1 },
        );
        defer sfc.deinit(testing.allocator);

        try testing.expectEqual(2, sfc.buf.len);
        try testing.expectEqual(0xFF, sfc.buf[0]);
        try testing.expectEqual(0xFF, sfc.buf[1]);
    }

    {
        // Downsampling. Note that we don't really use downsampling on Alpha1
        // as it's kind of pointless (a pixel is either just off or on).
        var sfc = try PackedImageSurface(pixel.Alpha1).init(
            testing.allocator,
            4,
            4,
            .{ .a = 1 },
        );
        defer sfc.deinit(testing.allocator);

        sfc.downsample(testing.allocator);

        try testing.expectEqual(1, sfc.buf.len);
        try testing.expectEqual(1, sfc.width);
        try testing.expectEqual(1, sfc.height);
        try testing.expectEqual(pixel.Pixel{ .alpha1 = .{ .a = 1 } }, sfc.getPixel(0, 0));
    }

    {
        // Downsampling with a pixel off (will render the whole downsampled
        // pixel off as per the Alpha1 implementation).
        var sfc = try PackedImageSurface(pixel.Alpha1).init(
            testing.allocator,
            4,
            4,
            .{ .a = 1 },
        );
        defer sfc.deinit(testing.allocator);

        sfc.putPixel(0, 0, .{ .alpha1 = .{ .a = 0 } });
        sfc.downsample(testing.allocator);

        try testing.expectEqual(1, sfc.buf.len);
        try testing.expectEqual(1, sfc.width);
        try testing.expectEqual(1, sfc.height);
        try testing.expectEqual(pixel.Pixel{ .alpha1 = .{ .a = 0 } }, sfc.getPixel(0, 0));
    }
}
