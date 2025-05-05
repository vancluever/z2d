// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024-2025 Chris Marchesi

//! Pixel types represented by the library.

const debug = @import("std").debug;
const math = @import("std").math;
const mem = @import("std").mem;
const meta = @import("std").meta;
const testing = @import("std").testing;

const compositor = @import("compositor.zig");

const colorpkg = @import("color.zig");
const Color = colorpkg.Color;

const runCases = @import("internal/util.zig").runCases;
const TestingError = @import("internal/util.zig").TestingError;

/// Format descriptors for the pixel formats supported by the library:
///
/// * `.rgba` is 24-bit truecolor as an 8-bit depth RGB, *with* alpha channel.
/// * `.rgb` is 24-bit truecolor as an 8-bit depth RGB, *without* alpha channel.
/// * `.alpha8` is an 8-bit alpha channel.
/// * `.alpha4` is an 4-bit alpha channel.
/// * `.alpha2` is an 2-bit alpha channel.
/// * `.alpha1` is a 1-bit alpha channel.
pub const Format = enum {
    rgb,
    rgba,
    alpha8,
    alpha4,
    alpha2,
    alpha1,
};

/// Represents a stride (contiguous range) of pixels of a certain type.
///
/// "Stride" here is ambiguous, it could be a line, a sub-section of a line, or
/// multiple lines, if those lines wrap without gaps.
///
/// Note that all strides represent real pixel memory, most likely residing in
/// the `Surface` they came from. Keep this in mind when writing to their
/// contents.
pub const Stride = union(Format) {
    rgb: []RGB,
    rgba: []RGBA,
    alpha8: []Alpha8,
    alpha4: struct {
        pub const T = Alpha4;
        buf: []u8,
        px_offset: usize,
        px_len: usize,
    },
    alpha2: struct {
        pub const T = Alpha2;
        buf: []u8,
        px_offset: usize,
        px_len: usize,
    },
    alpha1: struct {
        pub const T = Alpha1;
        buf: []u8,
        px_offset: usize,
        px_len: usize,
    },

    /// Returns the pixel length of the stride.
    pub fn pxLen(dst: Stride) usize {
        return switch (dst) {
            inline .rgb, .rgba, .alpha8 => |d| d.len,
            inline .alpha4, .alpha2, .alpha1 => |d| d.px_len,
        };
    }

    /// Copies the `src` stride into `dst`. The pixel length of `dst` is
    /// expected to be greater than or equal to `src`.
    pub fn copy(dst: Stride, src: Stride) void {
        switch (dst) {
            inline .rgb, .rgba, .alpha8 => |d| @typeInfo(@TypeOf(d)).Pointer.child.copySrcStride(d, src),
            inline .alpha4, .alpha2, .alpha1 => |d| @TypeOf(d).T.copyStride(d, src),
        }
    }

    /// Runs the single compositor operation described by `operator` with the
    /// supplied `dst` and `src` . `src` must be as long or longer than `dst`;
    /// shorter strides will cause safety-checked undefined behavior.
    pub fn composite(dst: Stride, src: Stride, operator: compositor.Operator) void {
        compositor.StrideCompositor.run(dst, &.{ .operator = operator, .src = .{ .surface = src } });
    }
};

/// Represents an interface as a union of the pixel formats.
pub const Pixel = union(Format) {
    rgb: RGB,
    rgba: RGBA,
    alpha8: Alpha8,
    alpha4: Alpha4,
    alpha2: Alpha2,
    alpha1: Alpha1,

    /// Returns `true` if the supplied pixels are equal.
    pub fn equal(self: Pixel, other: Pixel) bool {
        return switch (self) {
            inline else => |px| px.equal(other),
        };
    }

    /// Runs a single compositor operation described by `operator` against the
    /// supplied pixels.
    pub fn composite(dst: Pixel, src: Pixel, operator: compositor.Operator) Pixel {
        return compositor.runPixel(dst, src, operator);
    }

    /// Initializes a wrapped RGBA pixel from the supplied color verb.
    pub fn fromColor(color: Color.InitArgs) Pixel {
        return colorpkg.LinearRGB.fromColor(Color.init(color)).encodeRGBA().asPixel();
    }
};

/// Describes a 24-bit RGB format.
pub const RGB = packed struct(u32) {
    r: u8,
    g: u8,
    b: u8,
    _padding: u8 = 0,

    /// The format descriptor for this pixel format.
    pub const format: Format = .rgb;

    /// Returns a pixel from a clamped 0-1 value.
    pub fn fromClamped(r: f64, g: f64, b: f64) RGB {
        return .{
            .r = @intFromFloat(255 * math.clamp(r, 0, 1)),
            .g = @intFromFloat(255 * math.clamp(g, 0, 1)),
            .b = @intFromFloat(255 * math.clamp(b, 0, 1)),
        };
    }

    /// Returns the pixel translated to RGB.
    pub fn fromPixel(p: Pixel) RGB {
        return switch (p) {
            .rgb => |q| q,
            .rgba => |q| .{
                // Fully opaque since we drop alpha channel
                .r = q.r,
                .g = q.g,
                .b = q.b,
            },
            .alpha8, .alpha4, .alpha2, .alpha1 => .{
                // No color channel data, opaque black
                .r = 0,
                .g = 0,
                .b = 0,
            },
        };
    }

    /// Copies the `src` stride into `dst`. The pixel length of `dst` is
    /// expected to be greater than or equal to `src`.
    pub fn copyStride(dst: []RGB, src: Stride) void {
        switch (src) {
            inline .rgb, .rgba => |_src| mem.copyForwards(RGB, dst, @ptrCast(_src)),
            .alpha8, .alpha4, .alpha2, .alpha1 => @memset(dst, mem.zeroes(RGB)),
        }
    }

    /// Returns an average of the pixels in the supplied slice. The average of
    /// a zero-length slice is pure black.
    ///
    /// This function is limited to 256 entries; any higher than this is
    /// safety-checked undefined behavior.
    pub fn average(ps: []const RGB) RGB {
        debug.assert(ps.len <= 256);
        if (ps.len == 0) return .{ .r = 0, .g = 0, .b = 0 };

        var r: u16 = 0;
        var g: u16 = 0;
        var b: u16 = 0;

        for (ps) |p| {
            r += p.r;
            g += p.g;
            b += p.b;
        }

        return .{
            .r = @intCast(r / ps.len),
            .g = @intCast(g / ps.len),
            .b = @intCast(b / ps.len),
        };
    }

    /// Returns this pixel as an interface.
    pub fn asPixel(self: RGB) Pixel {
        return .{ .rgb = self };
    }

    /// Returns `true` if the supplied pixels are equal.
    pub fn equal(self: RGB, other: Pixel) bool {
        return switch (other) {
            .rgb => |o| self.r == o.r and self.g == o.g and self.b == o.b,
            else => false,
        };
    }
};

/// Describes a 32-bit RGBA format.
///
/// Note that all compositing operations in z2d expect a pre-multiplied alpha.
/// You can convert between pre-multiplied and straight alpha using `multiply`
/// and `demultiply`. Additionally, `fromClamped` takes straight alpha.
pub const RGBA = packed struct(u32) {
    r: u8,
    g: u8,
    b: u8,
    a: u8,

    /// The format descriptor for this pixel format.
    pub const format: Format = .rgba;

    /// Returns a pixel from a clamped 0-1 value. The helper expects the values
    /// as straight alpha and will pre-multiply the values for you.
    pub fn fromClamped(r: f64, g: f64, b: f64, a: f64) RGBA {
        const rc = math.clamp(r, 0, 1);
        const gc = math.clamp(g, 0, 1);
        const bc = math.clamp(b, 0, 1);
        const ac = math.clamp(a, 0, 1);
        const result: RGBA = .{
            .r = @intFromFloat(@round(255.0 * rc)),
            .g = @intFromFloat(@round(255.0 * gc)),
            .b = @intFromFloat(@round(255.0 * bc)),
            .a = @intFromFloat(@round(255.0 * ac)),
        };
        return result.multiply();
    }

    /// Returns the pixel translated to RGBA.
    pub fn fromPixel(p: Pixel) RGBA {
        return switch (p) {
            .rgb => |q| .{
                // Special case: we assume that RGB pixels are always opaque
                .r = q.r,
                .g = q.g,
                .b = q.b,
                .a = 255,
            },
            .rgba => |q| q,
            .alpha8 => |q| .{
                // No color channel data, so black w/alpha
                .r = 0,
                .g = 0,
                .b = 0,
                .a = q.a,
            },
            .alpha4, .alpha2, .alpha1 => .{
                // No color channel data, so black w/alpha
                .r = 0,
                .g = 0,
                .b = 0,
                .a = Alpha8.fromPixel(p).a,
            },
        };
    }

    /// Copies the `src` stride into `dst`. The pixel length of `dst` is
    /// expected to be greater than or equal to `src`.
    pub fn copyStride(dst: []RGBA, src: Stride) void {
        switch (src) {
            .rgb => |_src| {
                for (0.._src.len) |i| dst[i] = .{
                    .r = _src[i].r,
                    .g = _src[i].g,
                    .b = _src[i].b,
                    .a = 255,
                };
            },
            .rgba => |_src| @memcpy(dst, _src),
            .alpha8 => |_src| {
                for (0.._src.len) |i| dst[i] = .{
                    .r = 0,
                    .g = 0,
                    .b = 0,
                    .a = _src[i].a,
                };
            },
            inline .alpha4, .alpha2, .alpha1 => |_src| {
                for (0.._src.px_len) |i| {
                    const s = Alpha8.fromPixel(
                        @TypeOf(_src).T.getFromPacked(_src.buf, i + _src.px_offset).asPixel(),
                    );
                    dst[i] = .{
                        .r = 0,
                        .g = 0,
                        .b = 0,
                        .a = s.a,
                    };
                }
            },
        }
    }

    /// Returns an average of the pixels in the supplied slice. The average of
    /// a zero-length slice is transparent black.
    ///
    /// This function is limited to 256 entries; any higher than this is
    /// safety-checked undefined behavior.
    pub fn average(ps: []const RGBA) RGBA {
        debug.assert(ps.len <= 256);
        if (ps.len == 0) return .{ .r = 0, .g = 0, .b = 0, .a = 0 };

        var r: u16 = 0;
        var g: u16 = 0;
        var b: u16 = 0;
        var a: u16 = 0;

        for (ps) |p| {
            r += p.r;
            g += p.g;
            b += p.b;
            a += p.a;
        }

        return .{
            .r = @intCast(r / ps.len),
            .g = @intCast(g / ps.len),
            .b = @intCast(b / ps.len),
            .a = @intCast(a / ps.len),
        };
    }

    /// Returns this pixel as an interface.
    pub fn asPixel(self: RGBA) Pixel {
        return .{ .rgba = self };
    }

    /// Returns `true` if the supplied pixels are equal.
    pub fn equal(self: RGBA, other: Pixel) bool {
        return switch (other) {
            .rgba => |o| self.r == o.r and self.g == o.g and self.b == o.b and self.a == o.a,
            else => false,
        };
    }

    /// Returns a new RGBA value, with the color values multiplied by the alpha
    /// (as alpha / 255).
    pub fn multiply(self: RGBA) RGBA {
        return .{
            .r = @intCast(@as(u16, self.r) * self.a / 255),
            .g = @intCast(@as(u16, self.g) * self.a / 255),
            .b = @intCast(@as(u16, self.b) * self.a / 255),
            .a = self.a,
        };
    }

    /// Returns a new RGBA value, with the color values de-multiplied by the
    /// alpha.
    ///
    /// While this is designed to reverse pre-multiplied alpha values (the
    /// product of multiply), the reversed value may not be 100% accurate to
    /// the original due to remainder loss.
    ///
    /// As a special case, a zero alpha de-multiplies into transparent black.
    pub fn demultiply(self: RGBA) RGBA {
        if (self.a == 0) return .{ .r = 0, .g = 0, .b = 0, .a = 0 };
        return .{
            .r = @intCast(@as(u16, self.r) * 255 / self.a),
            .g = @intCast(@as(u16, self.g) * 255 / self.a),
            .b = @intCast(@as(u16, self.b) * 255 / self.a),
            .a = self.a,
        };
    }
};

/// Describes an 8-bit alpha channel-only format.
pub const Alpha8 = Alpha(.alpha8);

/// Describes a 4-bit alpha channel-only format.
pub const Alpha4 = Alpha(.alpha4);

/// Describes a 2-bit alpha channel-only format.
pub const Alpha2 = Alpha(.alpha2);

/// Describes a 1-bit alpha channel-only format.
pub const Alpha1 = Alpha(.alpha1);

comptime {
    debug.assert(@bitSizeOf(Alpha8) == 8);
    debug.assert(@bitSizeOf(Alpha4) == 4);
    debug.assert(@bitSizeOf(Alpha2) == 2);
    debug.assert(@bitSizeOf(Alpha1) == 1);
}

/// Returns a generated alpha-channel pixel type.
///
/// All alpha types that are less than 1 byte can be appropriately packed where
/// possible; this is done in `surface.PackedImageSurface` for our 4, 2, and
/// 1-bit alpha channel formats.
fn Alpha(comptime fmt: Format) type {
    return packed struct {
        const Self = @This();

        const NumBits: usize = switch (fmt) {
            .alpha8 => 8,
            .alpha4 => 4,
            .alpha2 => 2,
            .alpha1 => 1,
            else => @compileError("unsupported tag"),
        };

        const MaxInt: IntType = @intCast((1 << NumBits) - 1);

        a: IntType,

        /// The underlying integer for the alpha channel (and the packed
        /// struct).
        pub const IntType = meta.Int(.unsigned, NumBits);

        /// The format descriptor for this pixel format.
        pub const format: Format = fmt;

        /// Shorthand for a fully-opaque pixel in this format.
        pub const Opaque: Self = @bitCast(MaxInt);

        /// Returns the pixel translated to the alpha format.
        pub fn fromPixel(p: Pixel) Self {
            return switch (p) {
                .rgb => .{
                    // Special case: we assume that RGB pixels are always opaque
                    .a = MaxInt,
                },
                inline .rgba, .alpha8, .alpha4, .alpha2 => |q| .{ .a = shlr(IntType, q.a) },
                .alpha1 => |q| .{
                    // Short-circuit to on/off * MaxInt
                    .a = @intCast(q.a * MaxInt),
                },
            };
        }

        /// Copies the `src` stride into `dst`. The pixel length of `dst` is
        /// expected to be greater than or equal to `src`.
        pub fn copyStride(dst: anytype, src: Stride) void {
            if (@TypeOf(dst) == []Self) return copyStride_unpacked(dst, src);
            copyStride_packed(dst, src);
        }

        fn copyStride_unpacked(dst: []Self, src: Stride) void {
            comptime debug.assert(NumBits == 8);
            switch (src) {
                .rgb => @memset(dst, @bitCast(MaxInt)),
                .rgba => |_src| {
                    for (0.._src.len) |i| dst[i] = .{ .a = _src[i].a };
                },
                .alpha8 => |_src| @memcpy(dst, _src),
                inline .alpha4, .alpha2, .alpha1 => |_src| {
                    for (0.._src.px_len) |i| {
                        const s = fromPixel(
                            @TypeOf(_src).T.getFromPacked(_src.buf, i + _src.px_offset).asPixel(),
                        );
                        dst[i] = .{ .a = s.a };
                    }
                },
            }
        }

        fn copyStride_packed(dst: anytype, src: Stride) void {
            comptime debug.assert(NumBits < 8);
            comptime debug.assert(@TypeOf(dst).T == Self);
            switch (src) {
                .rgb => paintPackedStride(dst.buf, dst.px_offset, dst.px_len, Opaque),
                inline .rgba, .alpha8 => |_src| {
                    for (0.._src.len) |i| {
                        const s = fromPixel(_src[i].asPixel());
                        setInPacked(dst.buf, i + dst.px_offset, s);
                    }
                },
                inline .alpha4, .alpha2, .alpha1 => |_src| {
                    for (0.._src.px_len) |i| {
                        const s = fromPixel(
                            @TypeOf(_src).T.getFromPacked(_src.buf, i + _src.px_offset).asPixel(),
                        );
                        setInPacked(dst.buf, i + dst.px_offset, s);
                    }
                },
            }
        }

        fn shlr(
            comptime target_T: type,
            val: anytype,
        ) target_T {
            if (val == 0) return @intCast(val);
            const src_T = @TypeOf(val);
            if (target_T == src_T) return val;

            const from_bits = @typeInfo(src_T).int.bits;
            const to_bits = @typeInfo(target_T).int.bits;
            if (from_bits > to_bits) {
                return @intCast(val >> from_bits - to_bits);
            }

            // For scaling up (left shift), we use a repeating-bit padding
            // scheme to make sure that there is as little error as possible.
            // As our cases are very simple, we can reduce this to a lookup
            // table of the difference between our source and target bits:
            //
            // 2, 4 should accommodate u2 to u4 and u4 to u8 (2x bit-difference)
            // 6 should accommodate u2 to u8 (3x bit-difference)
            //
            // All of our other cases are fast-pathed, e.g. zero is
            // short-circuited above, and all scaling from alpha1 is just
            // multiplied to MaxInt.
            //
            // Reference:
            //   https://forum.pjrc.com/index.php?threads/fast-changing-range-or-bits-of-a-number-e-g-0-31-to-0-255.55921/post-204509
            // Archive link:
            //   https://web.archive.org/web/20241129054306/https://forum.pjrc.com/index.php?threads/fast-changing-range-or-bits-of-a-number-e-g-0-31-to-0-255.55921/#post-204509
            const _val: u16 = @intCast(val);
            return switch (to_bits - from_bits) {
                2, 4 => @intCast((_val << to_bits - from_bits) + _val),
                6 => @intCast((_val << to_bits - from_bits) |
                    (_val << to_bits - 2 * from_bits) |
                    (_val << to_bits - 3 * from_bits) |
                    (_val)),
                else => @compileError("invalid bit difference in lookup table"),
            };
        }

        /// Returns an average of the pixels in the supplied slice. The average of
        /// a zero-length slice is transparent.
        ///
        /// This function is limited to 256 entries; any higher than this is
        /// safety-checked undefined behavior.
        pub fn average(ps: []const Self) Self {
            debug.assert(ps.len <= 256);
            if (ps.len == 0) return .{ .a = 0 };

            var a: u16 = 0;

            for (ps) |p| {
                a += p.a;
            }

            return .{
                .a = @intCast(a / ps.len),
            };
        }

        /// Returns this pixel as an interface.
        pub fn asPixel(self: Self) Pixel {
            return @unionInit(Pixel, @tagName(fmt), self);
        }

        /// Returns `true` if the supplied pixels are equal.
        pub fn equal(self: Self, other: Pixel) bool {
            return switch (other) {
                fmt => |o| self.a == o.a,
                else => false,
            };
        }

        /// Utility function to get a pixel from a supplied packed buffer. Only
        /// available for packed types, for non-packed types (e.g., `Alpha8`),
        /// use standard indexing.
        pub fn getFromPacked(buf: []const u8, index: usize) Self {
            comptime debug.assert(NumBits < 8);
            const px_int = mem.readPackedInt(IntType, buf, index * @bitSizeOf(IntType), .little);
            return @bitCast(px_int);
        }

        /// Utility function to set a pixel in a supplied packed buffer. Only
        /// available for packed types, for non-packed types (e.g., `Alpha8`),
        /// use standard indexing.
        pub fn setInPacked(buf: []u8, index: usize, value: Self) void {
            comptime debug.assert(NumBits < 8);
            const px_int = @as(IntType, @bitCast(value));
            mem.writePackedInt(IntType, buf, index * @bitSizeOf(IntType), px_int, .little);
        }

        /// Copies a single pixel to the range starting at `index` and
        /// proceeding for `len`.
        ///
        /// `len` is unbounded; going past the length of the buffer is
        /// safety-checked undefined behavior.
        ///
        /// This function is only available for packed types, for non-packed
        /// types (e.g., `Alpha8`), use standard indexing.
        fn paintPackedStride(
            buf: []u8,
            index: usize,
            len: usize,
            value: Self,
        ) void {
            // This code has been ported from PackedImageSurface and trimmed
            // down; they serve similar purposes but this is designed for
            // utility behavior for packed alpha types.
            comptime debug.assert(NumBits < 8);
            const scale = 8 / NumBits;
            const end = (index + len);
            const slice_start: usize = index / scale;
            const slice_end: usize = end / scale;
            if (slice_start >= slice_end) {
                // There's nothing we can memset, just set the range individually.
                for (index..end) |idx| setInPacked(buf, idx, value);
                return;
            }
            const start_rem = index % scale;
            const slice_offset = @intFromBool(start_rem > 0);
            // Set our contiguous range
            paintPackedPixel(buf[slice_start + slice_offset .. slice_end], value);
            // Set the ends
            for (index..index + (scale - start_rem)) |idx| setInPacked(buf, idx, value);
            for (end - end % scale..end) |idx| setInPacked(buf, idx, value);
        }

        /// Paints the entire buffer with px in a packed fashion.
        ///
        /// This function is only available for packed types, for non-packed
        /// types (e.g., `Alpha8`), use standard indexing.
        fn paintPackedPixel(buf: []u8, px: Self) void {
            // This code has been ported from PackedImageSurface and trimmed
            // down; they serve similar purposes but this is designed for
            // utility behavior for packed alpha types.
            comptime debug.assert(NumBits < 8);
            if (meta.eql(px, mem.zeroes(Self))) {
                // Short-circuit to writing zeroes if the pixel we're setting is zero
                @memset(buf, 0);
                return;
            }

            const px_u8: u8 = px_u8: {
                const px_int = @as(IntType, @bitCast(px));
                break :px_u8 px_int;
            };
            var packed_px: u8 = 0;
            var sh: usize = 0;
            while (sh <= 8 - NumBits) : (sh += NumBits) {
                packed_px |= px_u8 << @intCast(sh);
            }

            @memset(buf, packed_px);
        }
    };
}

test "pixel interface, asPixel" {
    const rgb: RGB = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC };
    const rgba: RGBA = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC, .a = 0xDD };
    const alpha8: Alpha8 = .{ .a = 0xDD };
    const alpha4: Alpha4 = .{ .a = 0xD };
    const alpha2: Alpha2 = .{ .a = 2 };
    const alpha1: Alpha1 = .{ .a = 1 };

    try testing.expectEqual(Pixel{ .rgb = rgb }, rgb.asPixel());
    try testing.expectEqual(Pixel{ .rgba = rgba }, rgba.asPixel());
    try testing.expectEqual(Pixel{ .alpha8 = alpha8 }, alpha8.asPixel());
    try testing.expectEqual(Pixel{ .alpha4 = alpha4 }, alpha4.asPixel());
    try testing.expectEqual(Pixel{ .alpha2 = alpha2 }, alpha2.asPixel());
    try testing.expectEqual(Pixel{ .alpha1 = alpha1 }, alpha1.asPixel());
}

test "pixel interface, average" {
    const rgb = [_]RGB{
        .{ .r = 1, .g = 5, .b = 9 },
        .{ .r = 2, .g = 6, .b = 10 },
        .{ .r = 3, .g = 7, .b = 11 },
        .{ .r = 4, .g = 8, .b = 12 },
    };
    const rgb_expected: RGB = .{ .r = 2, .g = 6, .b = 10 };

    const rgba = [_]RGBA{
        .{ .r = 1, .g = 5, .b = 9, .a = 13 },
        .{ .r = 2, .g = 6, .b = 10, .a = 14 },
        .{ .r = 3, .g = 7, .b = 11, .a = 15 },
        .{ .r = 4, .g = 8, .b = 12, .a = 16 },
    };
    const rgba_expected: RGBA = .{ .r = 2, .g = 6, .b = 10, .a = 14 };

    const alpha8 = [_]Alpha8{
        .{ .a = 13 },
        .{ .a = 14 },
        .{ .a = 15 },
        .{ .a = 16 },
    };
    const alpha8_expected: Alpha8 = .{ .a = 14 };

    const alpha4 = [_]Alpha4{
        .{ .a = 3 },
        .{ .a = 4 },
        .{ .a = 5 },
        .{ .a = 6 },
    };
    const alpha4_expected: Alpha4 = .{ .a = 4 };

    const alpha2 = [_]Alpha2{
        .{ .a = 0 },
        .{ .a = 1 },
        .{ .a = 2 },
        .{ .a = 3 },
    };
    const alpha2_expected: Alpha2 = .{ .a = 1 };

    const alpha1_full = [_]Alpha1{
        .{ .a = 1 },
        .{ .a = 1 },
        .{ .a = 1 },
        .{ .a = 1 },
    };
    const alpha1_full_expected: Alpha1 = .{ .a = 1 };

    const alpha1_partial = [_]Alpha1{
        .{ .a = 1 },
        .{ .a = 0 },
        .{ .a = 1 },
        .{ .a = 1 },
    };
    const alpha1_partial_expected: Alpha1 = .{ .a = 0 };

    try testing.expectEqual(rgb_expected, RGB.average(&rgb));
    try testing.expectEqual(rgba_expected, RGBA.average(&rgba));
    try testing.expectEqual(alpha8_expected, Alpha8.average(&alpha8));
    try testing.expectEqual(alpha4_expected, Alpha4.average(&alpha4));
    try testing.expectEqual(alpha2_expected, Alpha2.average(&alpha2));
    try testing.expectEqual(alpha1_full_expected, Alpha1.average(&alpha1_full));
    try testing.expectEqual(alpha1_partial_expected, Alpha1.average(&alpha1_partial));
}

test "RGBA, multiply/demultiply" {
    {
        // Note that multiply/demultiply calls are NOT reversible, due to remainder
        // loss. The test below reflects that.
        // AA = 170, BB = 187, CC = 204
        const rgba: RGBA = .{ .r = 170, .g = 187, .b = 204, .a = 128 };
        const expected_multiplied: RGBA = .{ .r = 85, .g = 93, .b = 102, .a = 128 };
        const expected_demultiplied: RGBA = .{ .r = 169, .g = 185, .b = 203, .a = 128 };

        try testing.expectEqual(expected_multiplied, rgba.multiply());
        try testing.expectEqual(expected_demultiplied, expected_multiplied.demultiply());
    }

    {
        // Handling zero alpha
        const rgba: RGBA = .{ .r = 170, .g = 187, .b = 204, .a = 0 };
        const expected_multiplied: RGBA = .{ .r = 0, .g = 0, .b = 0, .a = 0 };

        try testing.expectEqual(expected_multiplied, rgba.multiply());
        try testing.expectEqual(expected_multiplied, expected_multiplied.demultiply());
    }
}

test "RGB, fromClamped" {
    try testing.expectEqual(RGB{ .r = 76, .g = 153, .b = 229 }, RGB.fromClamped(0.3, 0.6, 0.9));
    try testing.expectEqual(RGB{ .r = 0, .g = 0, .b = 0 }, RGB.fromClamped(-1, -1, -1));
    try testing.expectEqual(RGB{ .r = 255, .g = 255, .b = 255 }, RGB.fromClamped(2, 2, 2));
}

test "RGBA, fromClamped" {
    try testing.expectEqual(
        RGBA{ .r = 77, .g = 153, .b = 230, .a = 255 },
        RGBA.fromClamped(0.3, 0.6, 0.9, 1),
    );
    try testing.expectEqual(
        RGBA{ .r = 38, .g = 76, .b = 115, .a = 128 },
        RGBA.fromClamped(0.3, 0.6, 0.9, 0.5),
    );
    try testing.expectEqual(
        RGBA{ .r = 0, .g = 0, .b = 0, .a = 0 },
        RGBA.fromClamped(-1, -1, -1, -1),
    );
    try testing.expectEqual(
        RGBA{ .r = 255, .g = 255, .b = 255, .a = 255 },
        RGBA.fromClamped(2, 2, 2, 2),
    );
    try testing.expectEqual(
        RGBA{ .r = 128, .g = 128, .b = 128, .a = 128 },
        RGBA.fromClamped(2, 2, 2, 0.5),
    );
}

test "fromPixel" {
    // RGB
    try testing.expectEqual(
        RGB{ .r = 11, .g = 22, .b = 33 },
        RGB.fromPixel(.{ .rgb = .{ .r = 11, .g = 22, .b = 33 } }),
    );
    try testing.expectEqual(
        RGB{ .r = 11, .g = 22, .b = 33 },
        RGB.fromPixel(.{ .rgba = .{ .r = 11, .g = 22, .b = 33, .a = 128 } }),
    );
    try testing.expectEqual(
        RGB{ .r = 0, .g = 0, .b = 0 },
        RGB.fromPixel(.{ .alpha8 = .{ .a = 128 } }),
    );
    try testing.expectEqual(
        RGB{ .r = 0, .g = 0, .b = 0 },
        RGB.fromPixel(.{ .alpha4 = .{ .a = 10 } }),
    );
    try testing.expectEqual(
        RGB{ .r = 0, .g = 0, .b = 0 },
        RGB.fromPixel(.{ .alpha2 = .{ .a = 2 } }),
    );
    try testing.expectEqual(
        RGB{ .r = 0, .g = 0, .b = 0 },
        RGB.fromPixel(.{ .alpha1 = .{ .a = 1 } }),
    );

    // RGBA
    try testing.expectEqual(
        RGBA{ .r = 11, .g = 22, .b = 33, .a = 255 },
        RGBA.fromPixel(.{ .rgb = .{ .r = 11, .g = 22, .b = 33 } }),
    );
    try testing.expectEqual(
        RGBA{ .r = 11, .g = 22, .b = 33, .a = 128 },
        RGBA.fromPixel(.{ .rgba = .{ .r = 11, .g = 22, .b = 33, .a = 128 } }),
    );
    try testing.expectEqual(
        RGBA{ .r = 0, .g = 0, .b = 0, .a = 128 },
        RGBA.fromPixel(.{ .alpha8 = .{ .a = 128 } }),
    );
    try testing.expectEqual(
        RGBA{ .r = 0, .g = 0, .b = 0, .a = 102 },
        RGBA.fromPixel(.{ .alpha4 = .{ .a = 6 } }),
    );
    try testing.expectEqual(
        RGBA{ .r = 0, .g = 0, .b = 0, .a = 170 },
        RGBA.fromPixel(.{ .alpha2 = .{ .a = 2 } }),
    );
    try testing.expectEqual(
        RGBA{ .r = 0, .g = 0, .b = 0, .a = 255 },
        RGBA.fromPixel(.{ .alpha1 = .{ .a = 1 } }),
    );

    // Alpha8
    try testing.expectEqual(
        Alpha8{ .a = 255 },
        Alpha8.fromPixel(.{ .rgb = .{ .r = 11, .g = 22, .b = 33 } }),
    );
    try testing.expectEqual(
        Alpha8{ .a = 128 },
        Alpha8.fromPixel(.{ .rgba = .{ .r = 11, .g = 22, .b = 33, .a = 128 } }),
    );
    try testing.expectEqual(
        Alpha8{ .a = 128 },
        Alpha8.fromPixel(.{ .alpha8 = .{ .a = 128 } }),
    );
    try testing.expectEqual(
        Alpha8{ .a = 102 },
        Alpha8.fromPixel(.{ .alpha4 = .{ .a = 6 } }),
    );
    try testing.expectEqual(
        Alpha8{ .a = 170 },
        Alpha8.fromPixel(.{ .alpha2 = .{ .a = 2 } }),
    );
    try testing.expectEqual(
        Alpha8{ .a = 255 },
        Alpha8.fromPixel(.{ .alpha1 = .{ .a = 1 } }),
    );

    // Alpha4
    try testing.expectEqual(
        Alpha4{ .a = 15 },
        Alpha4.fromPixel(.{ .rgb = .{ .r = 11, .g = 22, .b = 33 } }),
    );
    try testing.expectEqual(
        Alpha4{ .a = 8 },
        Alpha4.fromPixel(.{ .rgba = .{ .r = 11, .g = 22, .b = 33, .a = 128 } }),
    );
    try testing.expectEqual(
        Alpha4{ .a = 8 },
        Alpha4.fromPixel(.{ .alpha8 = .{ .a = 128 } }),
    );
    try testing.expectEqual(
        Alpha4{ .a = 6 },
        Alpha4.fromPixel(.{ .alpha4 = .{ .a = 6 } }),
    );
    try testing.expectEqual(
        Alpha4{ .a = 10 },
        Alpha4.fromPixel(.{ .alpha2 = .{ .a = 2 } }),
    );
    try testing.expectEqual(
        Alpha4{ .a = 15 },
        Alpha4.fromPixel(.{ .alpha1 = .{ .a = 1 } }),
    );

    // Alpha2
    try testing.expectEqual(
        Alpha2{ .a = 3 },
        Alpha2.fromPixel(.{ .rgb = .{ .r = 11, .g = 22, .b = 33 } }),
    );
    try testing.expectEqual(
        Alpha2{ .a = 2 },
        Alpha2.fromPixel(.{ .rgba = .{ .r = 11, .g = 22, .b = 33, .a = 128 } }),
    );
    try testing.expectEqual(
        Alpha2{ .a = 2 },
        Alpha2.fromPixel(.{ .alpha8 = .{ .a = 128 } }),
    );
    try testing.expectEqual(
        Alpha2{ .a = 1 },
        Alpha2.fromPixel(.{ .alpha4 = .{ .a = 6 } }),
    );
    try testing.expectEqual(
        Alpha2{ .a = 2 },
        Alpha2.fromPixel(.{ .alpha2 = .{ .a = 2 } }),
    );
    try testing.expectEqual(
        Alpha2{ .a = 3 },
        Alpha2.fromPixel(.{ .alpha1 = .{ .a = 1 } }),
    );

    // Alpha1
    try testing.expectEqual(
        Alpha1{ .a = 1 },
        Alpha1.fromPixel(.{ .rgb = .{ .r = 11, .g = 22, .b = 33 } }),
    );
    try testing.expectEqual(
        Alpha1{ .a = 1 },
        Alpha1.fromPixel(.{ .rgba = .{ .r = 11, .g = 22, .b = 33, .a = 128 } }),
    );
    try testing.expectEqual(
        Alpha1{ .a = 0 },
        Alpha1.fromPixel(.{ .rgba = .{ .r = 11, .g = 22, .b = 33, .a = 127 } }),
    );
    try testing.expectEqual(
        Alpha1{ .a = 1 },
        Alpha1.fromPixel(.{ .alpha8 = .{ .a = 128 } }),
    );
    try testing.expectEqual(
        Alpha1{ .a = 0 },
        Alpha1.fromPixel(.{ .alpha8 = .{ .a = 127 } }),
    );
    try testing.expectEqual(
        Alpha1{ .a = 1 },
        Alpha1.fromPixel(.{ .alpha4 = .{ .a = 15 } }),
    );
    try testing.expectEqual(
        Alpha1{ .a = 1 },
        Alpha1.fromPixel(.{ .alpha2 = .{ .a = 3 } }),
    );
    try testing.expectEqual(
        Alpha1{ .a = 1 },
        Alpha1.fromPixel(.{ .alpha1 = .{ .a = 1 } }),
    );
}

test "Alpha, shlr" {
    // This only instantiates the type, shlr only exists in the namespace.
    const test_T = Alpha(.alpha8);
    {
        // zero
        try testing.expectEqual(0, test_T.shlr(u8, 0));
    }

    {
        // equal types
        try testing.expectEqual(255, test_T.shlr(u8, @as(u8, 255)));
    }

    {
        // shift down
        try testing.expectEqual(15, test_T.shlr(u4, @as(u8, 255)));
        try testing.expectEqual(3, test_T.shlr(u2, @as(u8, 255)));
        try testing.expectEqual(1, test_T.shlr(u1, @as(u8, 255)));
        try testing.expectEqual(0, test_T.shlr(u1, @as(u8, 127)));

        try testing.expectEqual(3, test_T.shlr(u2, @as(u4, 15)));
        try testing.expectEqual(1, test_T.shlr(u2, @as(u4, 4)));
        try testing.expectEqual(0, test_T.shlr(u2, @as(u4, 3)));
        try testing.expectEqual(1, test_T.shlr(u1, @as(u4, 15)));
        try testing.expectEqual(0, test_T.shlr(u1, @as(u4, 7)));

        try testing.expectEqual(1, test_T.shlr(u1, @as(u2, 3)));
        try testing.expectEqual(0, test_T.shlr(u1, @as(u2, 1)));
    }

    {
        // shift up (u2)
        try testing.expectEqual(5, test_T.shlr(u4, @as(u2, 1)));
        try testing.expectEqual(10, test_T.shlr(u4, @as(u2, 2)));
        try testing.expectEqual(15, test_T.shlr(u4, @as(u2, 3)));

        try testing.expectEqual(85, test_T.shlr(u8, @as(u2, 1)));
        try testing.expectEqual(170, test_T.shlr(u8, @as(u2, 2)));
        try testing.expectEqual(255, test_T.shlr(u8, @as(u2, 3)));
    }

    {
        // shift up (u4)
        try testing.expectEqual(17, test_T.shlr(u8, @as(u4, 1)));
        try testing.expectEqual(34, test_T.shlr(u8, @as(u4, 2)));
        try testing.expectEqual(51, test_T.shlr(u8, @as(u4, 3)));
        try testing.expectEqual(68, test_T.shlr(u8, @as(u4, 4)));
        try testing.expectEqual(85, test_T.shlr(u8, @as(u4, 5)));
        try testing.expectEqual(102, test_T.shlr(u8, @as(u4, 6)));
        try testing.expectEqual(119, test_T.shlr(u8, @as(u4, 7)));
        try testing.expectEqual(136, test_T.shlr(u8, @as(u4, 8)));
        try testing.expectEqual(153, test_T.shlr(u8, @as(u4, 9)));
        try testing.expectEqual(170, test_T.shlr(u8, @as(u4, 10)));
        try testing.expectEqual(187, test_T.shlr(u8, @as(u4, 11)));
        try testing.expectEqual(204, test_T.shlr(u8, @as(u4, 12)));
        try testing.expectEqual(221, test_T.shlr(u8, @as(u4, 13)));
        try testing.expectEqual(238, test_T.shlr(u8, @as(u4, 14)));
        try testing.expectEqual(255, test_T.shlr(u8, @as(u4, 15)));
    }

    {
        // invalid cases that (deliberately) generate compile errors
        //
        // NOTE: This is commented out since we cannot test compile errors
        // currently. Comment out to test ad-hoc. There's an accepted Zig
        // proposal for this so once it will get implemented eventually, after
        // which we can enable permanently.
        //
        // try testing.expectEqual(255, test_T.shlr(u8, @as(u1, 1)));
    }
}

test "equal" {
    const rgb_a: Pixel = .{ .rgb = .{ .r = 0x11, .g = 0x22, .b = 0x33 } };
    const rgb_b: Pixel = .{ .rgb = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC } };
    const rgba_a: Pixel = .{ .rgba = .{ .r = 0x11, .g = 0x22, .b = 0x33, .a = 0x44 } };
    const rgba_b: Pixel = .{ .rgba = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC, .a = 0xDD } };
    const alpha8_a: Pixel = .{ .alpha8 = .{ .a = 0x44 } };
    const alpha8_b: Pixel = .{ .alpha8 = .{ .a = 0xDD } };
    const alpha4_a: Pixel = .{ .alpha4 = .{ .a = 0x4 } };
    const alpha4_b: Pixel = .{ .alpha4 = .{ .a = 0xD } };
    const alpha2_a: Pixel = .{ .alpha2 = .{ .a = 1 } };
    const alpha2_b: Pixel = .{ .alpha2 = .{ .a = 2 } };
    const alpha1_a: Pixel = .{ .alpha1 = .{ .a = 0 } };
    const alpha1_b: Pixel = .{ .alpha1 = .{ .a = 1 } };

    try testing.expect(rgb_a.equal(rgb_a));
    try testing.expect(!rgb_a.equal(rgb_b));
    try testing.expect(!rgb_a.equal(rgba_a));

    try testing.expect(rgba_a.equal(rgba_a));
    try testing.expect(!rgba_a.equal(rgba_b));
    try testing.expect(!rgba_a.equal(rgb_a));

    try testing.expect(alpha8_a.equal(alpha8_a));
    try testing.expect(!alpha8_a.equal(alpha8_b));
    try testing.expect(!alpha8_a.equal(rgb_a));

    try testing.expect(alpha4_a.equal(alpha4_a));
    try testing.expect(!alpha4_a.equal(alpha4_b));
    try testing.expect(!alpha4_a.equal(rgb_a));

    try testing.expect(alpha2_a.equal(alpha2_a));
    try testing.expect(!alpha2_a.equal(alpha2_b));
    try testing.expect(!alpha2_a.equal(rgb_a));

    try testing.expect(alpha1_a.equal(alpha1_a));
    try testing.expect(!alpha1_a.equal(alpha1_b));
    try testing.expect(!alpha1_a.equal(rgb_a));
}

test "RGBA endianness" {
    const rgba: RGBA = .{ .r = 13, .g = 228, .b = 223, .a = 229 }; // turquoise, 90% opacity
    const bytes: [4]u8 = @bitCast(rgba);
    try testing.expectEqual(13, bytes[0]);
    try testing.expectEqual(228, bytes[1]);
    try testing.expectEqual(223, bytes[2]);
    try testing.expectEqual(229, bytes[3]);
}

test "Pixel.fromColor" {
    const name = "Pixel.fromColor";
    const cases = [_]struct {
        name: []const u8,
        expected: Pixel,
        args: Color.InitArgs,
    }{
        .{
            .name = "rgb",
            .expected = .{ .rgba = .{ .r = 64, .g = 128, .b = 191, .a = 255 } },
            .args = .{ .rgb = .{ 0.25, 0.5, 0.75 } },
        },
        .{
            .name = "rgba",
            .expected = .{ .rgba = .{ .r = 57, .g = 115, .b = 172, .a = 230 } },
            .args = .{ .rgba = .{ 0.25, 0.5, 0.75, 0.9 } },
        },
        .{
            .name = "srgb",
            .expected = .{ .rgba = .{ .r = 12, .g = 55, .b = 135, .a = 255 } },
            .args = .{ .srgb = .{ 0.25, 0.5, 0.75 } },
        },
        .{
            .name = "srgba",
            .expected = .{ .rgba = .{ .r = 10, .g = 49, .b = 121, .a = 230 } },
            .args = .{ .srgba = .{ 0.25, 0.5, 0.75, 0.9 } },
        },
        .{
            .name = "hsl",
            .expected = .{ .rgba = .{ .r = 0, .g = 255, .b = 255, .a = 255 } },
            .args = .{ .hsl = .{ 180, 1, 0.5 } },
        },
        .{
            .name = "hsla",
            .expected = .{ .rgba = .{ .r = 0, .g = 230, .b = 230, .a = 230 } },
            .args = .{ .hsla = .{ 180, 1, 0.5, 0.9 } },
        },
    };
    const TestFn = struct {
        fn f(tc: anytype) TestingError!void {
            try testing.expectEqualDeep(tc.expected, Pixel.fromColor(tc.args));
        }
    };
    try runCases(name, cases, TestFn.f);
}
