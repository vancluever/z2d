// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024 Chris Marchesi

//! Pixel types represented by the library.

const debug = @import("std").debug;
const math = @import("std").math;
const meta = @import("std").meta;
const testing = @import("std").testing;

/// Errors related to Pixel operations.
pub const Error = error{
    /// Strict pixel conversion using fromPixel failed due to the exact
    /// concrete type not matching. To to do a less strict conversion, use
    /// `copySrc`.
    InvalidFormat,
};

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

/// Represents an interface as a union of the pixel formats.
pub const Pixel = union(Format) {
    rgb: RGB,
    rgba: RGBA,
    alpha8: Alpha8,
    alpha4: Alpha4,
    alpha2: Alpha2,
    alpha1: Alpha1,

    /// Returns the result of compositing the supplied pixel over this one (the
    /// Porter-Duff src-over operation). All pixel types with color channels
    /// are expected to be pre-multiplied.
    pub fn srcOver(dst: Pixel, src: Pixel) Pixel {
        return switch (dst) {
            inline else => |d| d.srcOver(src).asPixel(),
        };
    }

    /// Returns the result of compositing the supplied pixel in this one (the
    /// Porter-Duff dst-in operation). All pixel types with color channels are
    /// expected to be pre-multiplied.
    pub fn dstIn(dst: Pixel, src: Pixel) Pixel {
        return switch (dst) {
            inline else => |d| d.dstIn(src).asPixel(),
        };
    }

    /// Returns `true` if the supplied pixels are equal.
    pub fn equal(self: Pixel, other: Pixel) bool {
        return switch (self) {
            inline else => |px| px.equal(other),
        };
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

    /// Returns this pixel as an interface.
    pub fn fromPixel(p: Pixel) Error!RGB {
        return switch (p) {
            Format.rgb => |q| q,
            else => error.InvalidFormat,
        };
    }

    /// Returns the pixel transformed by the Porter-Duff "src" operation. This
    /// is essentially a cast from the source pixel.
    pub fn copySrc(p: Pixel) RGB {
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

    /// Returns an average of the pixels in the supplied slice. The average of
    /// a zero-length slice is pure black.
    pub fn average(ps: []const RGB) RGB {
        if (ps.len == 0) return .{ .r = 0, .g = 0, .b = 0 };

        var r: u32 = 0;
        var g: u32 = 0;
        var b: u32 = 0;

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

    /// Returns the result of compositing the supplied pixel over this one (the
    /// Porter-Duff src-over operation). All pixel types with color channels
    /// are expected to be pre-multiplied.
    pub fn srcOver(dst: RGB, src: Pixel) RGB {
        return switch (src) {
            .rgb => |s| .{
                .r = s.r,
                .g = s.g,
                .b = s.b,
            },
            .rgba => |s| .{
                .r = srcOverColor(s.r, dst.r, s.a),
                .g = srcOverColor(s.g, dst.g, s.a),
                .b = srcOverColor(s.b, dst.b, s.a),
            },
            .alpha8 => |s| .{
                .r = srcOverColor(0, dst.r, s.a),
                .g = srcOverColor(0, dst.g, s.a),
                .b = srcOverColor(0, dst.b, s.a),
            },
            .alpha4, .alpha2, .alpha1 => a: {
                const s = Alpha8.copySrc(src);
                break :a .{
                    .r = srcOverColor(0, dst.r, s.a),
                    .g = srcOverColor(0, dst.g, s.a),
                    .b = srcOverColor(0, dst.b, s.a),
                };
            },
        };
    }

    /// Returns the result of compositing the supplied pixel in this one (the
    /// Porter-Duff dst-in operation). All pixel types with color channels are
    /// expected to be pre-multiplied.
    pub fn dstIn(dst: RGB, src: Pixel) RGB {
        return switch (src) {
            // Special case for RGB: just return the destination pixel (we
            // assume that every RGB pixel has full opacity).
            .rgb => .{
                .r = dst.r,
                .g = dst.g,
                .b = dst.b,
            },
            .rgba => |s| .{
                .r = dstInColor(dst.r, s.a),
                .g = dstInColor(dst.g, s.a),
                .b = dstInColor(dst.b, s.a),
            },
            .alpha8 => |s| .{
                .r = dstInColor(dst.r, s.a),
                .g = dstInColor(dst.g, s.a),
                .b = dstInColor(dst.b, s.a),
            },
            .alpha4, .alpha2, .alpha1 => a: {
                const s = Alpha8.copySrc(src);
                break :a .{
                    .r = dstInColor(dst.r, s.a),
                    .g = dstInColor(dst.g, s.a),
                    .b = dstInColor(dst.b, s.a),
                };
            },
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
        return .{
            .r = @intFromFloat(255 * rc * ac),
            .g = @intFromFloat(255 * gc * ac),
            .b = @intFromFloat(255 * bc * ac),
            .a = @intFromFloat(255 * ac),
        };
    }

    /// Returns this pixel as an interface.
    pub fn fromPixel(p: Pixel) Error!RGBA {
        return switch (p) {
            Format.rgba => |q| q,
            else => error.InvalidFormat,
        };
    }

    /// Returns the pixel transformed by the Porter-Duff "src" operation. This
    /// is essentially a cast from the source pixel.
    pub fn copySrc(p: Pixel) RGBA {
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
                .a = Alpha8.copySrc(p).a,
            },
        };
    }

    /// Returns an average of the pixels in the supplied slice. The average of
    /// a zero-length slice is transparent black.
    pub fn average(ps: []const RGBA) RGBA {
        if (ps.len == 0) return .{ .r = 0, .g = 0, .b = 0, .a = 0 };

        var r: u32 = 0;
        var g: u32 = 0;
        var b: u32 = 0;
        var a: u32 = 0;

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
            .r = @intCast(@as(u32, self.r) * self.a / 255),
            .g = @intCast(@as(u32, self.g) * self.a / 255),
            .b = @intCast(@as(u32, self.b) * self.a / 255),
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
            .r = @intCast(@as(u32, self.r) * 255 / self.a),
            .g = @intCast(@as(u32, self.g) * 255 / self.a),
            .b = @intCast(@as(u32, self.b) * 255 / self.a),
            .a = self.a,
        };
    }

    /// Returns the result of compositing the supplied pixel over this one (the
    /// Porter-Duff src-over operation). All pixel types with color channels
    /// are expected to be pre-multiplied.
    pub fn srcOver(dst: RGBA, src: Pixel) RGBA {
        return switch (src) {
            .rgb => |s| .{
                .r = s.r,
                .g = s.g,
                .b = s.b,
                .a = 255,
            },
            .rgba => |s| .{
                .r = srcOverColor(s.r, dst.r, s.a),
                .g = srcOverColor(s.g, dst.g, s.a),
                .b = srcOverColor(s.b, dst.b, s.a),
                .a = srcOverAlpha(u8, s.a, dst.a),
            },
            .alpha8 => |s| .{
                .r = srcOverColor(0, dst.r, s.a),
                .g = srcOverColor(0, dst.g, s.a),
                .b = srcOverColor(0, dst.b, s.a),
                .a = srcOverAlpha(u8, s.a, dst.a),
            },
            .alpha4, .alpha2, .alpha1 => a: {
                const s = Alpha8.copySrc(src);
                break :a .{
                    .r = srcOverColor(0, dst.r, s.a),
                    .g = srcOverColor(0, dst.g, s.a),
                    .b = srcOverColor(0, dst.b, s.a),
                    .a = srcOverAlpha(u8, s.a, dst.a),
                };
            },
        };
    }

    /// Returns the result of compositing the supplied pixel in this one (the
    /// Porter-Duff dst-in operation). All pixel types with color channels are
    /// expected to be pre-multiplied.
    pub fn dstIn(dst: RGBA, src: Pixel) RGBA {
        return switch (src) {
            .rgb => .{
                .r = dst.r,
                .g = dst.g,
                .b = dst.b,
                .a = dst.a,
            },
            .rgba => |s| .{
                .r = dstInColor(dst.r, s.a),
                .g = dstInColor(dst.g, s.a),
                .b = dstInColor(dst.b, s.a),
                .a = dstInAlpha(u8, s.a, dst.a),
            },
            .alpha8 => |s| .{
                .r = dstInColor(dst.r, s.a),
                .g = dstInColor(dst.g, s.a),
                .b = dstInColor(dst.b, s.a),
                .a = dstInAlpha(u8, s.a, dst.a),
            },
            .alpha4, .alpha2, .alpha1 => a: {
                const s = Alpha8.copySrc(src);
                break :a .{
                    .r = dstInColor(dst.r, s.a),
                    .g = dstInColor(dst.g, s.a),
                    .b = dstInColor(dst.b, s.a),
                    .a = dstInAlpha(u8, s.a, dst.a),
                };
            },
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

        /// Returns this pixel as an interface.
        pub fn fromPixel(p: Pixel) Error!Self {
            return switch (p) {
                fmt => |q| q,
                else => error.InvalidFormat,
            };
        }

        /// Returns the pixel transformed by the Porter-Duff "src" operation. This
        /// is essentially a cast from the source pixel.
        pub fn copySrc(p: Pixel) Self {
            return switch (p) {
                .rgb => .{
                    // Special case: we assume that RGB pixels are always opaque
                    .a = MaxInt,
                },
                .rgba => |q| .{
                    .a = shlr(IntType, q.a),
                },
                .alpha8 => |q| .{
                    .a = shlr(IntType, q.a),
                },
                .alpha4 => |q| .{
                    .a = shlr(IntType, q.a),
                },
                .alpha2 => |q| .{
                    .a = shlr(IntType, q.a),
                },
                .alpha1 => |q| .{
                    // Short-circuit to on/off * MaxInt
                    .a = @intCast(q.a * MaxInt),
                },
            };
        }

        inline fn shlr(
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
        pub fn average(ps: []const Self) Self {
            if (ps.len == 0) return .{ .a = 0 };

            var a: u32 = 0;

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

        /// Returns the result of compositing the supplied pixel over this one (the
        /// Porter-Duff src-over operation).
        pub fn srcOver(dst: Self, src: Pixel) Self {
            return switch (src) {
                .rgb => .{
                    .a = MaxInt,
                },
                else => a: {
                    const sa = copySrc(src).a;
                    break :a .{
                        .a = srcOverAlpha(IntType, sa, dst.a),
                    };
                },
            };
        }

        /// Returns the result of compositing the supplied pixel in this one (the
        /// Porter-Duff dst-in operation).
        pub fn dstIn(dst: Self, src: Pixel) Self {
            return switch (src) {
                .rgb => .{
                    .a = dst.a,
                },
                else => a: {
                    const sa = copySrc(src).a;
                    break :a .{
                        .a = dstInAlpha(IntType, sa, dst.a),
                    };
                },
            };
        }
    };
}

inline fn srcOverColor(sca: u8, dca: u8, sa: u8) u8 {
    const _sca: u16 = @intCast(sca);
    const _dca: u16 = @intCast(dca);
    const _sa: u16 = @intCast(sa);
    return @intCast(_sca + _dca * (255 - _sa) / 255);
}

inline fn srcOverAlpha(comptime T: type, sa: T, da: T) T {
    const max: u16 = comptime max: {
        const bits = @typeInfo(T).int.bits;
        debug.assert(bits <= 8);
        break :max (1 << bits) - 1;
    };
    const _sa: u16 = @intCast(sa);
    const _da: u16 = @intCast(da);
    return @intCast(_sa + _da - _sa * _da / max);
}

inline fn dstInColor(dca: u8, sa: u8) u8 {
    const _dca: u16 = @intCast(dca);
    const _sa: u16 = @intCast(sa);
    return @intCast(_dca * _sa / 255);
}

inline fn dstInAlpha(comptime T: type, sa: T, da: T) T {
    const max: u16 = comptime max: {
        const bits = @typeInfo(T).int.bits;
        debug.assert(bits <= 8);
        break :max (1 << bits) - 1;
    };
    const _sa: u16 = @intCast(sa);
    const _da: u16 = @intCast(da);
    return @intCast(_sa * _da / max);
}

test "pixel interface, fromPixel" {
    const rgb: RGB = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC };
    const rgba: RGBA = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC, .a = 0xDD };
    const alpha8: Alpha8 = .{ .a = 0xDD };
    const alpha4: Alpha4 = .{ .a = 0xD };
    const alpha2: Alpha2 = .{ .a = 2 };
    const alpha1: Alpha1 = .{ .a = 1 };

    try testing.expectEqual(RGB.fromPixel(.{ .rgb = rgb }), rgb);
    try testing.expectError(error.InvalidFormat, RGB.fromPixel(.{ .rgba = rgba }));

    try testing.expectEqual(RGBA.fromPixel(.{ .rgba = rgba }), rgba);
    try testing.expectError(error.InvalidFormat, RGBA.fromPixel(.{ .rgb = rgb }));

    try testing.expectEqual(Alpha8.fromPixel(.{ .alpha8 = alpha8 }), alpha8);
    try testing.expectError(error.InvalidFormat, Alpha8.fromPixel(.{ .rgb = rgb }));

    try testing.expectEqual(Alpha4.fromPixel(.{ .alpha4 = alpha4 }), alpha4);
    try testing.expectError(error.InvalidFormat, Alpha4.fromPixel(.{ .rgb = rgb }));

    try testing.expectEqual(Alpha2.fromPixel(.{ .alpha2 = alpha2 }), alpha2);
    try testing.expectError(error.InvalidFormat, Alpha2.fromPixel(.{ .rgb = rgb }));

    try testing.expectEqual(Alpha1.fromPixel(.{ .alpha1 = alpha1 }), alpha1);
    try testing.expectError(error.InvalidFormat, Alpha1.fromPixel(.{ .rgb = rgb }));
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
        RGBA{ .r = 76, .g = 153, .b = 229, .a = 255 },
        RGBA.fromClamped(0.3, 0.6, 0.9, 1),
    );
    try testing.expectEqual(
        RGBA{ .r = 38, .g = 76, .b = 114, .a = 127 },
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
        RGBA{ .r = 127, .g = 127, .b = 127, .a = 127 },
        RGBA.fromClamped(2, 2, 2, 0.5),
    );
}

test "copySrc" {
    // RGB
    try testing.expectEqual(
        RGB{ .r = 11, .g = 22, .b = 33 },
        RGB.copySrc(.{ .rgb = .{ .r = 11, .g = 22, .b = 33 } }),
    );
    try testing.expectEqual(
        RGB{ .r = 11, .g = 22, .b = 33 },
        RGB.copySrc(.{ .rgba = .{ .r = 11, .g = 22, .b = 33, .a = 128 } }),
    );
    try testing.expectEqual(
        RGB{ .r = 0, .g = 0, .b = 0 },
        RGB.copySrc(.{ .alpha8 = .{ .a = 128 } }),
    );
    try testing.expectEqual(
        RGB{ .r = 0, .g = 0, .b = 0 },
        RGB.copySrc(.{ .alpha4 = .{ .a = 10 } }),
    );
    try testing.expectEqual(
        RGB{ .r = 0, .g = 0, .b = 0 },
        RGB.copySrc(.{ .alpha2 = .{ .a = 2 } }),
    );
    try testing.expectEqual(
        RGB{ .r = 0, .g = 0, .b = 0 },
        RGB.copySrc(.{ .alpha1 = .{ .a = 1 } }),
    );

    // RGBA
    try testing.expectEqual(
        RGBA{ .r = 11, .g = 22, .b = 33, .a = 255 },
        RGBA.copySrc(.{ .rgb = .{ .r = 11, .g = 22, .b = 33 } }),
    );
    try testing.expectEqual(
        RGBA{ .r = 11, .g = 22, .b = 33, .a = 128 },
        RGBA.copySrc(.{ .rgba = .{ .r = 11, .g = 22, .b = 33, .a = 128 } }),
    );
    try testing.expectEqual(
        RGBA{ .r = 0, .g = 0, .b = 0, .a = 128 },
        RGBA.copySrc(.{ .alpha8 = .{ .a = 128 } }),
    );
    try testing.expectEqual(
        RGBA{ .r = 0, .g = 0, .b = 0, .a = 102 },
        RGBA.copySrc(.{ .alpha4 = .{ .a = 6 } }),
    );
    try testing.expectEqual(
        RGBA{ .r = 0, .g = 0, .b = 0, .a = 170 },
        RGBA.copySrc(.{ .alpha2 = .{ .a = 2 } }),
    );
    try testing.expectEqual(
        RGBA{ .r = 0, .g = 0, .b = 0, .a = 255 },
        RGBA.copySrc(.{ .alpha1 = .{ .a = 1 } }),
    );

    // Alpha8
    try testing.expectEqual(
        Alpha8{ .a = 255 },
        Alpha8.copySrc(.{ .rgb = .{ .r = 11, .g = 22, .b = 33 } }),
    );
    try testing.expectEqual(
        Alpha8{ .a = 128 },
        Alpha8.copySrc(.{ .rgba = .{ .r = 11, .g = 22, .b = 33, .a = 128 } }),
    );
    try testing.expectEqual(
        Alpha8{ .a = 128 },
        Alpha8.copySrc(.{ .alpha8 = .{ .a = 128 } }),
    );
    try testing.expectEqual(
        Alpha8{ .a = 102 },
        Alpha8.copySrc(.{ .alpha4 = .{ .a = 6 } }),
    );
    try testing.expectEqual(
        Alpha8{ .a = 170 },
        Alpha8.copySrc(.{ .alpha2 = .{ .a = 2 } }),
    );
    try testing.expectEqual(
        Alpha8{ .a = 255 },
        Alpha8.copySrc(.{ .alpha1 = .{ .a = 1 } }),
    );

    // Alpha4
    try testing.expectEqual(
        Alpha4{ .a = 15 },
        Alpha4.copySrc(.{ .rgb = .{ .r = 11, .g = 22, .b = 33 } }),
    );
    try testing.expectEqual(
        Alpha4{ .a = 8 },
        Alpha4.copySrc(.{ .rgba = .{ .r = 11, .g = 22, .b = 33, .a = 128 } }),
    );
    try testing.expectEqual(
        Alpha4{ .a = 8 },
        Alpha4.copySrc(.{ .alpha8 = .{ .a = 128 } }),
    );
    try testing.expectEqual(
        Alpha4{ .a = 6 },
        Alpha4.copySrc(.{ .alpha4 = .{ .a = 6 } }),
    );
    try testing.expectEqual(
        Alpha4{ .a = 10 },
        Alpha4.copySrc(.{ .alpha2 = .{ .a = 2 } }),
    );
    try testing.expectEqual(
        Alpha4{ .a = 15 },
        Alpha4.copySrc(.{ .alpha1 = .{ .a = 1 } }),
    );

    // Alpha2
    try testing.expectEqual(
        Alpha2{ .a = 3 },
        Alpha2.copySrc(.{ .rgb = .{ .r = 11, .g = 22, .b = 33 } }),
    );
    try testing.expectEqual(
        Alpha2{ .a = 2 },
        Alpha2.copySrc(.{ .rgba = .{ .r = 11, .g = 22, .b = 33, .a = 128 } }),
    );
    try testing.expectEqual(
        Alpha2{ .a = 2 },
        Alpha2.copySrc(.{ .alpha8 = .{ .a = 128 } }),
    );
    try testing.expectEqual(
        Alpha2{ .a = 1 },
        Alpha2.copySrc(.{ .alpha4 = .{ .a = 6 } }),
    );
    try testing.expectEqual(
        Alpha2{ .a = 2 },
        Alpha2.copySrc(.{ .alpha2 = .{ .a = 2 } }),
    );
    try testing.expectEqual(
        Alpha2{ .a = 3 },
        Alpha2.copySrc(.{ .alpha1 = .{ .a = 1 } }),
    );

    // Alpha1
    try testing.expectEqual(
        Alpha1{ .a = 1 },
        Alpha1.copySrc(.{ .rgb = .{ .r = 11, .g = 22, .b = 33 } }),
    );
    try testing.expectEqual(
        Alpha1{ .a = 1 },
        Alpha1.copySrc(.{ .rgba = .{ .r = 11, .g = 22, .b = 33, .a = 128 } }),
    );
    try testing.expectEqual(
        Alpha1{ .a = 0 },
        Alpha1.copySrc(.{ .rgba = .{ .r = 11, .g = 22, .b = 33, .a = 127 } }),
    );
    try testing.expectEqual(
        Alpha1{ .a = 1 },
        Alpha1.copySrc(.{ .alpha8 = .{ .a = 128 } }),
    );
    try testing.expectEqual(
        Alpha1{ .a = 0 },
        Alpha1.copySrc(.{ .alpha8 = .{ .a = 127 } }),
    );
    try testing.expectEqual(
        Alpha1{ .a = 1 },
        Alpha1.copySrc(.{ .alpha4 = .{ .a = 15 } }),
    );
    try testing.expectEqual(
        Alpha1{ .a = 1 },
        Alpha1.copySrc(.{ .alpha2 = .{ .a = 3 } }),
    );
    try testing.expectEqual(
        Alpha1{ .a = 1 },
        Alpha1.copySrc(.{ .alpha1 = .{ .a = 1 } }),
    );
}

test "srcOver" {
    // Our colors, non-pre-multiplied.
    //
    // Note that some tests require the pre-multiplied alpha. For these, we do
    // the multiplication at the relevant site, as as most casts will drop
    // either the non-color or alpha channels.
    const fg: RGBA = .{ .r = 54, .g = 10, .b = 63, .a = 191 }; // purple, 75% opacity
    const bg: RGBA = .{ .r = 15, .g = 254, .b = 249, .a = 229 }; // turquoise, 90% opacity

    {
        // RGB
        const fg_rgb = RGB.copySrc(fg.asPixel());
        const bg_rgb = RGB.copySrc(bg.asPixel());
        try testing.expectEqualDeep(
            fg_rgb,
            bg_rgb.srcOver(fg_rgb.asPixel()),
        );
        try testing.expectEqualDeep(
            RGB{ .r = 43, .g = 70, .b = 109 },
            bg_rgb.srcOver(fg.multiply().asPixel()),
        );
        try testing.expectEqualDeep(
            RGB{ .r = 3, .g = 63, .b = 62 },
            bg_rgb.srcOver(Alpha8.copySrc(fg.asPixel()).asPixel()),
        );
        try testing.expectEqualDeep(
            RGB{ .r = 4, .g = 67, .b = 66 },
            bg_rgb.srcOver(Alpha4.copySrc(fg.asPixel()).asPixel()),
        );
        try testing.expectEqualDeep(
            RGB{ .r = 5, .g = 84, .b = 83 },
            bg_rgb.srcOver(Alpha2.copySrc(fg.asPixel()).asPixel()),
        );
        try testing.expectEqualDeep(
            RGB{ .r = 0, .g = 0, .b = 0 },
            bg_rgb.srcOver(.{ .alpha1 = .{ .a = 1 } }),
        );
    }

    {
        // RGBA
        const bg_mul = bg.multiply();
        try testing.expectEqualDeep(
            RGBA{ .r = 54, .g = 10, .b = 63, .a = 255 },
            bg_mul.srcOver(RGB.copySrc(fg.asPixel()).asPixel()),
        );
        try testing.expectEqualDeep(
            RGBA{ .r = 43, .g = 64, .b = 102, .a = 249 },
            bg_mul.srcOver(fg.multiply().asPixel()),
        );
        try testing.expectEqualDeep(
            RGBA{ .r = 3, .g = 57, .b = 55, .a = 249 },
            bg_mul.srcOver(Alpha8.copySrc(fg.asPixel()).asPixel()),
        );
        try testing.expectEqualDeep(
            RGBA{ .r = 3, .g = 60, .b = 59, .a = 249 },
            bg_mul.srcOver(Alpha4.copySrc(fg.asPixel()).asPixel()),
        );
        try testing.expectEqualDeep(
            RGBA{ .r = 4, .g = 76, .b = 74, .a = 247 },
            bg_mul.srcOver(Alpha2.copySrc(fg.asPixel()).asPixel()),
        );
        try testing.expectEqualDeep(
            RGBA{ .r = 0, .g = 0, .b = 0, .a = 255 },
            bg_mul.srcOver(.{ .alpha1 = .{ .a = 1 } }),
        );
    }

    {
        // Alpha8
        const bg_alpha8 = Alpha8.copySrc(bg.asPixel());
        try testing.expectEqualDeep(
            Alpha8{ .a = 255 },
            bg_alpha8.srcOver(RGB.copySrc(fg.asPixel()).asPixel()),
        );
        try testing.expectEqualDeep(
            Alpha8{ .a = 249 },
            bg_alpha8.srcOver(fg.asPixel()),
        );
        try testing.expectEqualDeep(
            Alpha8{ .a = 249 },
            bg_alpha8.srcOver(Alpha8.copySrc(fg.asPixel()).asPixel()),
        );
        try testing.expectEqualDeep(
            Alpha8{ .a = 249 },
            bg_alpha8.srcOver(Alpha4.copySrc(fg.asPixel()).asPixel()),
        );
        try testing.expectEqualDeep(
            Alpha8{ .a = 247 },
            bg_alpha8.srcOver(Alpha2.copySrc(fg.asPixel()).asPixel()),
        );
        try testing.expectEqualDeep(
            Alpha8{ .a = 255 },
            bg_alpha8.srcOver(.{ .alpha1 = .{ .a = 1 } }),
        );
    }

    {
        // Alpha4
        const bg_alpha4 = Alpha4.copySrc(bg.asPixel());
        try testing.expectEqualDeep(
            Alpha4{ .a = 15 },
            bg_alpha4.srcOver(RGB.copySrc(fg.asPixel()).asPixel()),
        );
        try testing.expectEqualDeep(
            Alpha4{ .a = 15 },
            bg_alpha4.srcOver(fg.asPixel()),
        );
        try testing.expectEqualDeep(
            Alpha4{ .a = 15 },
            bg_alpha4.srcOver(Alpha8.copySrc(fg.asPixel()).asPixel()),
        );
        try testing.expectEqualDeep(
            Alpha4{ .a = 15 },
            bg_alpha4.srcOver(Alpha4.copySrc(fg.asPixel()).asPixel()),
        );
        try testing.expectEqualDeep(
            Alpha4{ .a = 15 },
            bg_alpha4.srcOver(Alpha2.copySrc(fg.asPixel()).asPixel()),
        );
        try testing.expectEqualDeep(
            Alpha4{ .a = 15 },
            bg_alpha4.srcOver(.{ .alpha1 = .{ .a = 1 } }),
        );
    }

    {
        // Alpha2
        const bg_alpha2 = Alpha2.copySrc(bg.asPixel());
        try testing.expectEqualDeep(
            Alpha2{ .a = 3 },
            bg_alpha2.srcOver(RGB.copySrc(fg.asPixel()).asPixel()),
        );
        try testing.expectEqualDeep(
            Alpha2{ .a = 3 },
            bg_alpha2.srcOver(fg.asPixel()),
        );
        try testing.expectEqualDeep(
            Alpha2{ .a = 3 },
            bg_alpha2.srcOver(Alpha8.copySrc(fg.asPixel()).asPixel()),
        );
        try testing.expectEqualDeep(
            Alpha2{ .a = 3 },
            bg_alpha2.srcOver(Alpha4.copySrc(fg.asPixel()).asPixel()),
        );
        try testing.expectEqualDeep(
            Alpha2{ .a = 3 },
            bg_alpha2.srcOver(Alpha2.copySrc(fg.asPixel()).asPixel()),
        );
        try testing.expectEqualDeep(
            Alpha2{ .a = 3 },
            bg_alpha2.srcOver(.{ .alpha1 = .{ .a = 1 } }),
        );
    }

    {
        // Alpha1
        var bg_alpha1 = Alpha1.copySrc(bg.asPixel());
        try testing.expectEqualDeep(
            Alpha1{ .a = 1 },
            bg_alpha1.srcOver(RGB.copySrc(fg.asPixel()).asPixel()),
        );
        try testing.expectEqualDeep(
            Alpha1{ .a = 1 },
            bg_alpha1.srcOver(fg.asPixel()),
        );
        // Jack down our alpha channel by 1 to just demonstrate the error
        // boundary when scaling down from u8 to u1.
        var fg_127 = fg;
        fg_127.a = 127;
        try testing.expectEqualDeep(
            Alpha1{ .a = 1 }, // Still 1 here due to our bg opacity being 90%
            bg_alpha1.srcOver(fg_127.asPixel()),
        );

        bg_alpha1.a = 0; // Turn off bg alpha layer for rest of testing
        try testing.expectEqualDeep(
            Alpha1{ .a = 0 }, // Still 1 here due to our bg opacity being 90%
            bg_alpha1.srcOver(fg_127.asPixel()),
        );
        try testing.expectEqualDeep(
            Alpha1{ .a = 0 },
            bg_alpha1.srcOver(Alpha8.copySrc(fg_127.asPixel()).asPixel()),
        );
        try testing.expectEqualDeep(
            Alpha1{ .a = 0 },
            bg_alpha1.srcOver(Alpha4.copySrc(fg_127.asPixel()).asPixel()),
        );
        try testing.expectEqualDeep(
            Alpha1{ .a = 0 },
            bg_alpha1.srcOver(Alpha2.copySrc(fg_127.asPixel()).asPixel()),
        );
        try testing.expectEqualDeep(
            Alpha1{ .a = 1 },
            bg_alpha1.srcOver(.{ .alpha1 = .{ .a = 1 } }),
        );
    }
}

test "dstIn" {
    // Our colors, non-pre-multiplied.
    //
    // Note that some tests require the pre-multiplied alpha. For these, we do
    // the multiplication at the relevant site, as as most casts will drop
    // either the non-color or alpha channels.
    const fg: RGBA = .{ .r = 54, .g = 10, .b = 63, .a = 191 }; // purple, 75% opacity
    const bg: RGBA = .{ .r = 15, .g = 254, .b = 249, .a = 229 }; // turquoise, 90% opacity

    {
        // RGB
        const fg_rgb = RGB.copySrc(fg.asPixel());
        const bg_rgb = RGB.copySrc(bg.asPixel());
        try testing.expectEqualDeep(
            bg_rgb,
            bg_rgb.dstIn(fg_rgb.asPixel()),
        );
        try testing.expectEqualDeep(
            RGB{ .r = 11, .g = 190, .b = 186 },
            bg_rgb.dstIn(fg.multiply().asPixel()),
        );
        try testing.expectEqualDeep(
            RGB{ .r = 11, .g = 190, .b = 186 },
            bg_rgb.dstIn(Alpha8.copySrc(fg.asPixel()).asPixel()),
        );
        try testing.expectEqualDeep(
            RGB{ .r = 11, .g = 186, .b = 182 },
            bg_rgb.dstIn(Alpha4.copySrc(fg.asPixel()).asPixel()),
        );
        try testing.expectEqualDeep(
            RGB{ .r = 10, .g = 169, .b = 166 },
            bg_rgb.dstIn(Alpha2.copySrc(fg.asPixel()).asPixel()),
        );
        try testing.expectEqualDeep(
            RGB{ .r = 15, .g = 254, .b = 249 },
            bg_rgb.dstIn(.{ .alpha1 = .{ .a = 1 } }),
        );
    }

    {
        // RGBA
        const bg_mul = bg.multiply();
        try testing.expectEqualDeep(
            RGBA{ .r = 13, .g = 228, .b = 223, .a = 229 },
            bg_mul.dstIn(RGB.copySrc(fg.asPixel()).asPixel()),
        );
        try testing.expectEqualDeep(
            RGBA{ .r = 9, .g = 170, .b = 167, .a = 171 },
            bg_mul.dstIn(fg.multiply().asPixel()),
        );
        try testing.expectEqualDeep(
            RGBA{ .r = 9, .g = 170, .b = 167, .a = 171 },
            bg_mul.dstIn(Alpha8.copySrc(fg.asPixel()).asPixel()),
        );
        try testing.expectEqualDeep(
            RGBA{ .r = 9, .g = 167, .b = 163, .a = 167 },
            bg_mul.dstIn(Alpha4.copySrc(fg.asPixel()).asPixel()),
        );
        try testing.expectEqualDeep(
            RGBA{ .r = 8, .g = 152, .b = 148, .a = 152 },
            bg_mul.dstIn(Alpha2.copySrc(fg.asPixel()).asPixel()),
        );
        try testing.expectEqualDeep(
            RGBA{ .r = 13, .g = 228, .b = 223, .a = 229 },
            bg_mul.dstIn(.{ .alpha1 = .{ .a = 1 } }),
        );
    }

    {
        // Alpha8
        const bg_alpha8 = Alpha8.copySrc(bg.asPixel());
        try testing.expectEqualDeep(
            Alpha8{ .a = 229 },
            bg_alpha8.dstIn(RGB.copySrc(fg.asPixel()).asPixel()),
        );
        try testing.expectEqualDeep(
            Alpha8{ .a = 171 },
            bg_alpha8.dstIn(fg.asPixel()),
        );
        try testing.expectEqualDeep(
            Alpha8{ .a = 171 },
            bg_alpha8.dstIn(Alpha8.copySrc(fg.asPixel()).asPixel()),
        );
        try testing.expectEqualDeep(
            Alpha8{ .a = 167 },
            bg_alpha8.dstIn(Alpha4.copySrc(fg.asPixel()).asPixel()),
        );
        try testing.expectEqualDeep(
            Alpha8{ .a = 152 },
            bg_alpha8.dstIn(Alpha2.copySrc(fg.asPixel()).asPixel()),
        );
        try testing.expectEqualDeep(
            Alpha8{ .a = 229 },
            bg_alpha8.dstIn(.{ .alpha1 = .{ .a = 1 } }),
        );
    }

    {
        // Alpha4
        const bg_alpha4 = Alpha4.copySrc(bg.asPixel());
        try testing.expectEqualDeep(
            Alpha4{ .a = 14 },
            bg_alpha4.dstIn(RGB.copySrc(fg.asPixel()).asPixel()),
        );
        try testing.expectEqualDeep(
            Alpha4{ .a = 10 },
            bg_alpha4.dstIn(fg.asPixel()),
        );
        try testing.expectEqualDeep(
            Alpha4{ .a = 10 },
            bg_alpha4.dstIn(Alpha8.copySrc(fg.asPixel()).asPixel()),
        );
        try testing.expectEqualDeep(
            Alpha4{ .a = 10 },
            bg_alpha4.dstIn(Alpha4.copySrc(fg.asPixel()).asPixel()),
        );
        try testing.expectEqualDeep(
            Alpha4{ .a = 9 },
            bg_alpha4.dstIn(Alpha2.copySrc(fg.asPixel()).asPixel()),
        );
        try testing.expectEqualDeep(
            Alpha4{ .a = 14 },
            bg_alpha4.dstIn(.{ .alpha1 = .{ .a = 1 } }),
        );
    }

    {
        // Alpha4
        const bg_alpha2 = Alpha2.copySrc(bg.asPixel());
        try testing.expectEqualDeep(
            Alpha2{ .a = 3 },
            bg_alpha2.dstIn(RGB.copySrc(fg.asPixel()).asPixel()),
        );
        try testing.expectEqualDeep(
            Alpha2{ .a = 2 },
            bg_alpha2.dstIn(fg.asPixel()),
        );
        try testing.expectEqualDeep(
            Alpha2{ .a = 2 },
            bg_alpha2.dstIn(Alpha8.copySrc(fg.asPixel()).asPixel()),
        );
        try testing.expectEqualDeep(
            Alpha2{ .a = 2 },
            bg_alpha2.dstIn(Alpha4.copySrc(fg.asPixel()).asPixel()),
        );
        try testing.expectEqualDeep(
            Alpha2{ .a = 2 },
            bg_alpha2.dstIn(Alpha2.copySrc(fg.asPixel()).asPixel()),
        );
        try testing.expectEqualDeep(
            Alpha2{ .a = 3 },
            bg_alpha2.dstIn(.{ .alpha1 = .{ .a = 1 } }),
        );
    }

    {
        // Alpha1
        const bg_alpha1 = Alpha1.copySrc(bg.asPixel());
        try testing.expectEqualDeep(
            Alpha1{ .a = 1 },
            bg_alpha1.dstIn(RGB.copySrc(fg.asPixel()).asPixel()),
        );
        try testing.expectEqualDeep(
            Alpha1{ .a = 1 },
            bg_alpha1.dstIn(fg.asPixel()),
        );
        // Jack down our alpha channel by 1 to just demonstrate the error
        // boundary when scaling down from u8 to u1.
        var fg_127 = fg;
        fg_127.a = 127;
        try testing.expectEqualDeep(
            Alpha1{ .a = 0 },
            bg_alpha1.dstIn(fg_127.asPixel()),
        );
        try testing.expectEqualDeep(
            Alpha1{ .a = 0 },
            bg_alpha1.dstIn(Alpha8.copySrc(fg_127.asPixel()).asPixel()),
        );
        try testing.expectEqualDeep(
            Alpha1{ .a = 0 },
            bg_alpha1.dstIn(Alpha4.copySrc(fg_127.asPixel()).asPixel()),
        );
        try testing.expectEqualDeep(
            Alpha1{ .a = 0 },
            bg_alpha1.dstIn(Alpha2.copySrc(fg_127.asPixel()).asPixel()),
        );
        try testing.expectEqualDeep(
            Alpha1{ .a = 1 },
            bg_alpha1.dstIn(.{ .alpha1 = .{ .a = 1 } }),
        );
        try testing.expectEqualDeep(
            Alpha1{ .a = 0 },
            bg_alpha1.dstIn(.{ .alpha1 = .{ .a = 0 } }),
        );
    }
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
