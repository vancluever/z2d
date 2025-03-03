// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2025 Chris Marchesi

//! Color space functionality.
//!
//! Colors differ from pixel formats in that they do not represent data in
//! actual pixel memory, rather they provide a basis for providing a
//! user-friendly way to define color as values that translate better to the
//! human eye; e.g., HSL, where the user will supply the hue as the primary
//! method of changing the color, or gamma-corrected sRGB, for encoding to
//! images or transmitting to a destination that requires gamma-corrected data
//! to properly display lightness.
//!
//! This package serves the purpose of encoding and decoding between various
//! color spaces and the linear RGBA format that our image surfaces store pixel
//! data as (from which it can be further converted). It also provides
//! interpolation functions for supported color spaces (via
//! `InterpolationMethod`) which are utilized in other places in this library,
//! such as gradients.
//!
//! The recommended method to initialize colors is to use the `Color.init`
//! function, which allows you to specify colors in each color space with or
//! without alpha. This function utilizes the `init` functions in each
//! particular space.
//!
//! Most interaction with this package via other parts of the library will
//! take `Color.InitArgs` directly, saving you some boilerplate.
//!
//! Note that all color values are stored de-multiplied, and are expected to be
//! supplied as such (unless otherwise specified).

const builtin = @import("std").builtin;
const debug = @import("std").debug;
const math = @import("std").math;
const mem = @import("std").mem;
const testing = @import("std").testing;

const pixel = @import("pixel.zig");

const vector_length = @import("compositor.zig").vector_length;

const splat = @import("internal/util.zig").splat;
const vectorize = @import("internal/util.zig").vectorize;
const runCases = @import("internal/util.zig").runCases;
const TestingError = @import("internal/util.zig").TestingError;

/// Represents a union of the supported color spaces.
pub const Color = union(enum) {
    linear_rgb: LinearRGB,
    srgb: SRGB,
    hsl: HSL,

    /// A set of short-hand color initialization arguments to be used with
    /// `init`.
    ///
    /// With the exception of `rgb` (which matches `LinearRGB`, every tag that
    /// takes a set of f32 values matches its respective color space (e.g.,
    /// `.srgb` matches the `SRGB` space, `.hsl` matches `HSL`, etc). The
    /// non-alpha variants (tags without the "a" suffix) initialize with fully
    /// opaque alpha, while alpha can be supplied via the alpha variants (tags
    /// with the "a" suffix).
    ///
    /// Values are generally either 0-1 clamped, or 0-359 (for hue on polar
    /// color spaces).
    ///
    /// Examples:
    ///
    /// ```
    /// .{ .rgb = .{ 1, 0, 0 } }        // Linear RGB red
    /// .{ .srgba = .{ 0, 1, 1, 0.5 } } // sRGB cyan, half-alpha
    /// .{ .hsl = .{ 300, 1, 0.5 } }    // HSL, magenta
    /// ```
    pub const InitArgs = union(enum) {
        rgb: [3]f32,
        rgba: [4]f32,
        srgb: [3]f32,
        srgba: [4]f32,
        hsl: [3]f32,
        hsla: [4]f32,

        /// Use an existing color. Convenience field for functions that take
        /// `InitArgs` directly.
        color: Color,
    };

    /// Initializes a color using the shorthand arguments supplied in `args`.
    /// Values are appropriately clamped as if they were passed to the `init`
    /// function of the respective color space.
    pub fn init(args: InitArgs) Color {
        return switch (args) {
            .rgb => |a| LinearRGB.init(a[0], a[1], a[2], 1).asColor(),
            .rgba => |a| LinearRGB.init(a[0], a[1], a[2], a[3]).asColor(),
            .srgb => |a| SRGB.init(a[0], a[1], a[2], 1).asColor(),
            .srgba => |a| SRGB.init(a[0], a[1], a[2], a[3]).asColor(),
            .hsl => |a| HSL.init(a[0], a[1], a[2], 1).asColor(),
            .hsla => |a| HSL.init(a[0], a[1], a[2], a[3]).asColor(),
            .color => |a| a,
        };
    }
};

/// The set of supported interpolation methods. Serves as a front end for
/// interpolation.
///
/// Each interpolation method is reflective of either:
///
/// * The *interpolation color space*, for rectangular color spaces such as RGB.
///
/// * The *interpolation color space*, and the *polar interpolation method*, for
/// polar color spaces such as HSL.
///
/// The interpolation color space is the space where interpolation happens;
/// each color is converted to this color before interpolation.
///
/// For polar color spaces, the polar interpolation method is the direction
/// along the color circle that the interpolation moves, such as the shorter or
/// longer path.
pub const InterpolationMethod = union(enum) {
    /// Sub-methods for interpolation of polar color spaces.
    pub const Polar = enum {
        /// Interpolation follows the shorter of the two arcs between the
        /// starting and ending hues.
        shorter,

        /// Interpolation follows the longer of the two arcs between the
        /// starting and ending hues.
        longer,

        /// Interpolation follows the arc moving in the clockwise direction
        /// between the starting and ending hues.
        increasing,

        /// Interpolation follows the arc moving in the counter-clockwise
        /// direction between the starting and ending hues.
        decreasing,
    };

    linear_rgb: void,
    hsl: Polar,

    /// Runs interpolation using the supplied method, returning the color in
    /// the interpolation color space.
    pub fn interpolate(method: InterpolationMethod, a: Color, b: Color, t: f32) Color {
        return switch (method) {
            .linear_rgb => LinearRGB.interpolate(
                LinearRGB.fromColor(a),
                LinearRGB.fromColor(b),
                t,
            ).asColor(),
            .hsl => |polar_method| color: {
                break :color HSL.interpolate(
                    HSL.fromColor(a),
                    HSL.fromColor(b),
                    t,
                    polar_method,
                ).asColor();
            },
        };
    }

    /// Runs interpolation using the supplied method, returning a
    /// pre-multiplied RGBA pixel.
    pub fn interpolateEncode(method: InterpolationMethod, a: Color, b: Color, t: f32) pixel.RGBA {
        return switch (method) {
            .linear_rgb => LinearRGB.interpolateEncode(
                LinearRGB.fromColor(a),
                LinearRGB.fromColor(b),
                t,
            ),
            .hsl => |polar_method| color: {
                break :color HSL.interpolateEncode(
                    HSL.fromColor(a),
                    HSL.fromColor(b),
                    t,
                    polar_method,
                );
            },
        };
    }

    /// Vectorized version of `interpolate`. Designed for internal use by
    /// the compositor; YMMV when using externally.
    pub fn interpolateVec(
        method: InterpolationMethod,
        a: [vector_length]Color,
        b: [vector_length]Color,
        t: [vector_length]f32,
    ) LinearRGB.Vector {
        return switch (method) {
            .linear_rgb => LinearRGB.interpolateVec(
                LinearRGB.fromColorVec(a),
                LinearRGB.fromColorVec(b),
                t,
            ),
            .hsl => |polar_method| color: {
                break :color HSL.toRGBVec(HSL.interpolateVec(
                    HSL.fromColorVec(a),
                    HSL.fromColorVec(b),
                    t,
                    polar_method,
                ));
            },
        };
    }

    /// Vectorized version of `interpolateEncode`. Designed for internal use by
    /// the compositor; YMMV when using externally.
    pub fn interpolateEncodeVec(
        method: InterpolationMethod,
        a: [vector_length]Color,
        b: [vector_length]Color,
        t: [vector_length]f32,
    ) vectorize(pixel.RGBA) {
        return switch (method) {
            .linear_rgb => LinearRGB.interpolateEncodeVec(
                LinearRGB.fromColorVec(a),
                LinearRGB.fromColorVec(b),
                t,
            ),
            .hsl => |polar_method| color: {
                break :color HSL.interpolateEncodeVec(
                    HSL.fromColorVec(a),
                    HSL.fromColorVec(b),
                    t,
                    polar_method,
                );
            },
        };
    }
};

/// Represents a linear RGB value with alpha channel.
pub const LinearRGB = RGB(.linear);

/// Represents an sRGB value with a default gamma profile (2.2).
pub const SRGB = RGB(.srgb);

/// Tags for RGB color profiles.
const RGBProfile = enum {
    linear,
    srgb,
};

/// Type function for RGB-based color spaces, with comptime handling for gamma
/// correction.
///
/// Note that it's assumed that gamma correction is applied at rest, and
/// functions like `applyGamma` and `removeGamma` should normally should not
/// need to be used manually. For conversion between linear and non-linear
/// sRGB, use their respective higher-level types.
fn RGB(profile: RGBProfile) type {
    return struct {
        const Self = @This();

        /// The color profile for this sRGB type.
        pub const Profile = profile;

        /// The fast-gamma correction value.
        pub const gamma: f32 = switch (profile) {
            .linear => 1.0,
            .srgb => 2.2,
        };

        /// Represents this color space with vectorized fields.
        const Vector = vectorize(Self);

        r: f32,
        g: f32,
        b: f32,
        a: f32,

        /// Returns a value with the fields clamped to the expected 0-1 range.
        pub fn init(r: f32, g: f32, b: f32, a: f32) Self {
            return .{
                .r = math.clamp(r, 0, 1),
                .g = math.clamp(g, 0, 1),
                .b = math.clamp(b, 0, 1),
                .a = math.clamp(a, 0, 1),
            };
        }

        /// Returns the color translated to sRGB with this color profile.
        pub fn fromColor(src: Color) Self {
            return switch (src) {
                inline .linear_rgb, .srgb => |c| color: {
                    if (@TypeOf(c) == Self) break :color c;
                    const c_linear = c.removeGamma();
                    break :color (Self{
                        .r = c_linear.r,
                        .g = c_linear.g,
                        .b = c_linear.b,
                        .a = c_linear.a,
                    }).applyGamma();
                },
                .hsl => |h| color: {
                    const c_linear = h.toRGB();
                    break :color (Self{
                        .r = c_linear.r,
                        .g = c_linear.g,
                        .b = c_linear.b,
                        .a = c_linear.a,
                    }).applyGamma();
                },
            };
        }

        /// Vectorizes a vector-sized array of colors translated to sRGB,
        /// gamma-corrected.
        fn fromColorVec(src: [vector_length]Color) Self.Vector {
            var result: Self.Vector = undefined;
            for (src, 0..) |c, i| {
                const s = Self.fromColor(c);
                result.r[i] = s.r;
                result.g[i] = s.g;
                result.b[i] = s.b;
                result.a[i] = s.a;
            }
            return result;
        }

        /// Returns the color wrapped in the `Color` union.
        pub fn asColor(src: Self) Color {
            return switch (profile) {
                .linear => .{ .linear_rgb = src },
                .srgb => .{ .srgb = src },
            };
        }

        /// Converts from linear RGBA pixel format. The pixel is expected to be
        /// pre-multiplied.
        pub fn decodeRGBA(src: pixel.RGBA) Self {
            const src_demul = src.demultiply();
            return (Self{
                .r = @as(f32, @floatFromInt(src_demul.r)) / 255.0,
                .g = @as(f32, @floatFromInt(src_demul.g)) / 255.0,
                .b = @as(f32, @floatFromInt(src_demul.b)) / 255.0,
                .a = @as(f32, @floatFromInt(src_demul.a)) / 255.0,
            }).applyGamma();
        }

        /// Converts to linear pre-multiplied RGBA pixel format.
        pub fn encodeRGBA(src: Self) pixel.RGBA {
            // According to the CSS spec, colors are supposed to be rounded,
            // not truncated. Honor that here.
            //
            // Also, care needs to be taken to ensure we are doing
            // pre-multication in the correct order. Note that we are
            // de-multiplying before converting in decode, as such, we should
            // pre-multiply *after* encode. This ensures that the alpha value
            // can take advantage of rounding before it is applied to the
            // encoded value.
            const _src = src.removeGamma();
            return (pixel.RGBA{
                .r = @intFromFloat(@round(255.0 * _src.r)),
                .g = @intFromFloat(@round(255.0 * _src.g)),
                .b = @intFromFloat(@round(255.0 * _src.b)),
                .a = @intFromFloat(@round(255.0 * _src.a)),
            }).multiply();
        }

        /// Vectorized version of encodeRGBA, used internally.
        pub fn encodeRGBAVec(src: Self.Vector) vectorize(pixel.RGBA) {
            // NOTE: we have other implementations of a 16-bit vectorized RGBA
            // value in the compositor package. I'm refraining from making that
            // public for the time being as this is currently the only case
            // where we need it outside of that package, but it's a possibility
            // if its use grows.
            const _src = removeGammaVec(src);
            const result: struct {
                r: @Vector(vector_length, u16),
                g: @Vector(vector_length, u16),
                b: @Vector(vector_length, u16),
                a: @Vector(vector_length, u16),
            } = .{
                .r = @intFromFloat(@round(splat(f32, 255.0) * _src.r)),
                .g = @intFromFloat(@round(splat(f32, 255.0) * _src.g)),
                .b = @intFromFloat(@round(splat(f32, 255.0) * _src.b)),
                .a = @intFromFloat(@round(splat(f32, 255.0) * _src.a)),
            };
            return .{
                .r = @intCast(result.r * result.a / splat(u16, 255)),
                .g = @intCast(result.g * result.a / splat(u16, 255)),
                .b = @intCast(result.b * result.a / splat(u16, 255)),
                .a = @intCast(result.a),
            };
        }

        /// Converts from a RGBA pixel with no transformation (does not
        /// de-multiply, does not apply gamma).
        pub fn decodeRGBARaw(src: pixel.RGBA) Self {
            return .{
                .r = @as(f32, @floatFromInt(src.r)) / 255.0,
                .g = @as(f32, @floatFromInt(src.g)) / 255.0,
                .b = @as(f32, @floatFromInt(src.b)) / 255.0,
                .a = @as(f32, @floatFromInt(src.a)) / 255.0,
            };
        }

        /// Converts to a RGBA pixel with no transformation (does not
        /// pre-multiply, does not remove gamma).
        pub fn encodeRGBARaw(src: Self) pixel.RGBA {
            return .{
                .r = @intFromFloat(@round(255.0 * src.r)),
                .g = @intFromFloat(@round(255.0 * src.g)),
                .b = @intFromFloat(@round(255.0 * src.b)),
                .a = @intFromFloat(@round(255.0 * src.a)),
            };
        }

        /// Like encodeRGBARaw, but converts vectorized colors to vectorized RGBA
        /// values. Used internally.
        fn encodeRGBAVecRaw(src: Self.Vector) vectorize(pixel.RGBA) {
            return .{
                .r = @intFromFloat(@round(splat(f32, 255.0) * src.r)),
                .g = @intFromFloat(@round(splat(f32, 255.0) * src.g)),
                .b = @intFromFloat(@round(splat(f32, 255.0) * src.b)),
                .a = @intFromFloat(@round(splat(f32, 255.0) * src.a)),
            };
        }

        // Multiplication functions
        // TODO: We will likely move multiply/de-multiply over here, as we do
        // all of our interpolation operations in pre-multiplied alpha.

        /// Returns the value with the colors multiplied by the alpha.
        pub fn multiply(src: Self) Self {
            return .{
                .r = src.r * src.a,
                .g = src.g * src.a,
                .b = src.b * src.a,
                .a = src.a,
            };
        }

        /// Internally-used vectorized version of multiply.
        fn multiplyVec(src: Self.Vector) Self.Vector {
            return .{
                .r = src.r * src.a,
                .g = src.g * src.a,
                .b = src.b * src.a,
                .a = src.a,
            };
        }

        /// Returns the value with the colors divided by the alpha.
        pub fn demultiply(src: Self) Self {
            if (src.a == 0) return .{ .r = 0, .g = 0, .b = 0, .a = 0 };
            return .{
                .r = src.r / src.a,
                .g = src.g / src.a,
                .b = src.b / src.a,
                .a = src.a,
            };
        }

        /// Internally-used vectorized version of demultiply.
        fn demultiplyVec(src: Self.Vector) Self.Vector {
            return .{
                .r = src.r / src.a,
                .g = src.g / src.a,
                .b = src.b / src.a,
                .a = src.a,
            };
        }

        /// Applies the profile's fast-gamma value to the color, converting the
        /// color to a gamma-corrected value.
        pub fn applyGamma(src: Self) Self {
            return .{
                .r = math.pow(f32, src.r, 1 / gamma),
                .g = math.pow(f32, src.g, 1 / gamma),
                .b = math.pow(f32, src.b, 1 / gamma),
                .a = src.a,
            };
        }

        /// Removes the profile's fast-gamma value from the color, converting
        /// the color to a linear value.
        pub fn removeGamma(src: Self) Self {
            return .{
                .r = math.pow(f32, src.r, gamma),
                .g = math.pow(f32, src.g, gamma),
                .b = math.pow(f32, src.b, gamma),
                .a = src.a,
            };
        }

        /// Vectorized version of removeGamma.
        fn removeGammaVec(src: Self.Vector) Self.Vector {
            if (profile == .linear) {
                return src;
            }
            // math.pow is not implemented for vectors, so we need to do this
            // element-by-element.
            var result: Self.Vector = undefined;
            for (0..vector_length) |i| {
                result.r[i] = math.pow(f32, src.r[i], gamma);
                result.g[i] = math.pow(f32, src.g[i], gamma);
                result.b[i] = math.pow(f32, src.b[i], gamma);
                result.a[i] = src.a[i];
            }
            return result;
        }

        /// Does standard linear interpolation of the color, returning the
        /// de-multiplied form.
        pub fn interpolate(a: Self, b: Self, t: f32) Self {
            const a_mul = a.multiply();
            const b_mul = b.multiply();
            const interpolated: Self = .{
                .r = lerp(a_mul.r, b_mul.r, t),
                .g = lerp(a_mul.g, b_mul.g, t),
                .b = lerp(a_mul.b, b_mul.b, t),
                .a = lerp(a_mul.a, b_mul.a, t),
            };
            return interpolated.demultiply();
        }

        /// Internal interpolation function for vectors.
        fn interpolateVec(
            a: Self.Vector,
            b: Self.Vector,
            t: @Vector(vector_length, f32),
        ) Self.Vector {
            const a_mul = multiplyVec(a);
            const b_mul = multiplyVec(b);
            const interpolated: Self.Vector = .{
                .r = lerp(a_mul.r, b_mul.r, t),
                .g = lerp(a_mul.g, b_mul.g, t),
                .b = lerp(a_mul.b, b_mul.b, t),
                .a = lerp(a_mul.a, b_mul.a, t),
            };
            // Note that unlinke our vectorized interpolation, we need to
            // demultiply here as we expect these values to be at rest and be
            // processed more before they are encoded.
            return demultiplyVec(interpolated);
        }

        /// Performs standard linear interpolation and returns the value as a
        /// pre-multiplied RGBA value.
        pub fn interpolateEncode(a: Self, b: Self, t: f32) pixel.RGBA {
            const a_mul = a.multiply();
            const b_mul = b.multiply();
            const interpolated: Self = .{
                .r = lerp(a_mul.r, b_mul.r, t),
                .g = lerp(a_mul.g, b_mul.g, t),
                .b = lerp(a_mul.b, b_mul.b, t),
                .a = lerp(a_mul.a, b_mul.a, t),
            };
            return interpolated.encodeRGBARaw();
        }

        /// Like interpolateEncode, but runs on vectors.
        fn interpolateEncodeVec(
            a: Self.Vector,
            b: Self.Vector,
            t: @Vector(vector_length, f32),
        ) vectorize(pixel.RGBA) {
            const a_mul = multiplyVec(a);
            const b_mul = multiplyVec(b);
            const interpolated: Self.Vector = .{
                .r = lerp(a_mul.r, b_mul.r, t),
                .g = lerp(a_mul.g, b_mul.g, t),
                .b = lerp(a_mul.b, b_mul.b, t),
                .a = lerp(a_mul.a, b_mul.a, t),
            };
            return encodeRGBAVecRaw(interpolated);
        }
    };
}

// Parts of the HSL conversion code includes material copied from or derived
// from https://www.w3.org/TR/css-color-4/#the-hsl-notation. Copyright © 2024
// World Wide Web Consortium.
// https://www.w3.org/copyright/software-license-2023/

/// Represents an HSL (Hue, Saturation, Lightness) color value with alpha channel.
pub const HSL = struct {
    /// Represents this color space with vectorized fields.
    const Vector = vectorize(HSL);

    h: f32,
    s: f32,
    l: f32,
    a: f32,

    /// Returns a value with the fields appropriately set.
    ///
    /// * `h` (hue) is normalized to the 0-360 range (see below).
    /// * `s` (saturation), `l` (lightness), and `a` (alpha) are clamped
    /// between 0 and 1.
    ///
    /// Note that angles over 360 degrees are fully normalized to a 0-359 range
    /// (e.g., hue of 720 is converted to 0). Specifying a hue of 360 is an
    /// exception to this and is not wrapped so that one can interpolate the
    /// whole of the hue range (example: from 0 degrees (red) to 360 degrees
    /// (red).
    pub fn init(h: f32, s: f32, l: f32, a: f32) HSL {
        return .{
            .h = if (h < 0 or h > 360) @mod(h, 360) else h,
            .s = math.clamp(s, 0, 1),
            .l = math.clamp(l, 0, 1),
            .a = math.clamp(a, 0, 1),
        };
    }

    /// Returns the color translated to HSL.
    pub fn fromColor(src: Color) HSL {
        return switch (src) {
            inline .linear_rgb, .srgb => fromRGB(LinearRGB.fromColor(src)),
            .hsl => |h| h,
        };
    }

    /// Vectorizes a slice of colors translated to HSL.
    fn fromColorVec(src: [vector_length]Color) HSL.Vector {
        var result: HSL.Vector = undefined;
        for (src, 0..) |c, i| {
            const s = HSL.fromColor(c);
            result.h[i] = s.h;
            result.s[i] = s.s;
            result.l[i] = s.l;
            result.a[i] = s.a;
        }
        return result;
    }

    /// Returns the color wrapped in the `Color` union.
    pub fn asColor(src: HSL) Color {
        return .{ .hsl = src };
    }

    /// Converts from linear RGB to HSL. The data is expected to be
    /// non-multiplied and normalized to the 0-1 range.
    pub fn fromRGB(src: LinearRGB) HSL {
        const max = @max(src.r, @max(src.g, src.b));
        const min = @min(src.r, @min(src.g, src.b));
        const range = max - min;
        const light: f32 = (min + max) / 2;
        var sat: f32 = if (light == 0 or light == 1) 0 else (max - light) / @min(light, 1 - light);

        var hue: f32 = 0;
        if (range != 0) {
            if (max == src.r) {
                hue = 60 * @mod((src.g - src.b) / range, 6);
            } else if (max == src.g) {
                hue = 60 * ((src.b - src.r) / range + 2);
            } else if (max == src.b) {
                hue = 60 * ((src.r - src.g) / range + 4);
            }
        }

        // Rotate hue and fix saturation if we hit negative saturation. This
        // can happen when dealing with out-of-gamut colors from a particular
        // color space. See https://github.com/w3c/csswg-drafts/issues/9222
        if (sat < 0) {
            hue += 180;
            if (hue >= 360) {
                hue -= 360;
            }
            sat = @abs(sat);
        }

        return .{
            .h = hue,
            .s = sat,
            .l = light,
            .a = src.a,
        };
    }

    /// Converts to linear RGB, non-multiplied.
    pub fn toRGB(src: HSL) LinearRGB {
        var hue = @rem(src.h, 360);

        if (hue < 0) {
            hue += 360;
        }

        return .{
            .r = toRGBChannel(0, hue, src.s, src.l),
            .g = toRGBChannel(8, hue, src.s, src.l),
            .b = toRGBChannel(4, hue, src.s, src.l),
            .a = src.a,
        };
    }

    fn toRGBChannel(n: f32, hue: f32, sat: f32, light: f32) f32 {
        const k = @rem((n + hue / 30), 12);
        const a = sat * @min(light, 1 - light);
        return light - a * @max(-1, @min(k - 3, 9 - k, 1));
    }

    fn toRGBVec(src: HSL.Vector) LinearRGB.Vector {
        var hue = @rem(src.h, splat(f32, 360));
        hue = @select(f32, hue < splat(f32, 0), hue + splat(f32, 360), hue);

        return .{
            .r = toSRGBChannelVec(splat(f32, 0), hue, src.s, src.l),
            .g = toSRGBChannelVec(splat(f32, 8), hue, src.s, src.l),
            .b = toSRGBChannelVec(splat(f32, 4), hue, src.s, src.l),
            .a = src.a,
        };
    }

    fn toSRGBChannelVec(
        n: @Vector(vector_length, f32),
        hue: @Vector(vector_length, f32),
        sat: @Vector(vector_length, f32),
        light: @Vector(vector_length, f32),
    ) @Vector(vector_length, f32) {
        const k = @rem((n + hue / splat(f32, 30)), splat(f32, 12));
        const a = sat * @min(light, splat(f32, 1) - light);
        return light - a * @max(splat(f32, -1), @min(k - splat(f32, 3), splat(f32, 9) - k, splat(f32, 1)));
    }

    /// Returns the value with the colors multiplied by the alpha.
    pub fn multiply(src: HSL) HSL {
        return .{
            .h = src.h,
            .s = src.s * src.a,
            .l = src.l * src.a,
            .a = src.a,
        };
    }

    fn multiplyVec(src: HSL.Vector) HSL.Vector {
        return .{
            .h = src.h,
            .s = src.s * src.a,
            .l = src.l * src.a,
            .a = src.a,
        };
    }

    /// Returns the value with the colors divided by the alpha.
    pub fn demultiply(src: HSL) HSL {
        if (src.a == 0) return .{ .h = src.h, .s = 0, .l = 0, .a = 0 };
        return .{
            .h = src.h,
            .s = src.s / src.a,
            .l = src.l / src.a,
            .a = src.a,
        };
    }

    fn demultiplyVec(src: HSL.Vector) HSL.Vector {
        return .{
            .h = src.h,
            .s = @select(f32, src.a == splat(f32, 0), splat(f32, 0), src.s / src.a),
            .l = @select(f32, src.a == splat(f32, 0), splat(f32, 0), src.l / src.a),
            .a = src.a,
        };
    }

    /// Does standard linear interpolation of the color, returning the
    /// de-multiplied form.
    pub fn interpolate(a: HSL, b: HSL, t: f32, method: InterpolationMethod.Polar) HSL {
        const a_mul = a.multiply();
        const b_mul = b.multiply();
        var a_mul_h = a_mul.h;
        var b_mul_h = b_mul.h;

        switch (method) {
            .shorter => {
                if (b_mul_h - a_mul_h > 180) {
                    a_mul_h += 360;
                } else if (b_mul_h - a_mul_h < -180) {
                    b_mul_h += 360;
                }
            },
            .longer => {
                const delta = b_mul_h - a_mul_h;
                if (0 < delta and delta < 180) {
                    a_mul_h += 360;
                } else if (-180 < delta and delta <= 0) {
                    b_mul_h += 360;
                }
            },
            .increasing => {
                if (b_mul_h < a_mul_h) b_mul_h += 360;
            },
            .decreasing => {
                if (a_mul_h < b_mul_h) a_mul_h += 360;
            },
        }

        const h_result = lerpPolar(a_mul.h, a_mul_h, b_mul_h, t);
        return (HSL{
            .h = @mod(h_result, 360),
            .s = lerp(a_mul.s, b_mul.s, t),
            .l = lerp(a_mul.l, b_mul.l, t),
            .a = lerp(a_mul.a, b_mul.a, t),
        }).demultiply();
    }

    /// Internal interpolation function for vectors.
    fn interpolateVec(
        a: HSL.Vector,
        b: HSL.Vector,
        t: @Vector(vector_length, f32),
        method: InterpolationMethod.Polar,
    ) HSL.Vector {
        const a_mul = multiplyVec(a);
        const b_mul = multiplyVec(b);
        var a_mul_h = a_mul.h;
        var b_mul_h = b_mul.h;

        switch (method) {
            .shorter => {
                const gt_cond = b_mul_h - a_mul_h > splat(f32, 180);
                const lt_cond = b_mul_h - a_mul_h < splat(f32, -180);
                a_mul_h = @select(f32, gt_cond, a_mul_h + splat(f32, 360), a_mul_h);
                b_mul_h = @select(f32, lt_cond, b_mul_h + splat(f32, 360), b_mul_h);
            },
            .longer => {
                const delta = b_mul_h - a_mul_h;
                const zero_180_cond = (@intFromBool(splat(f32, 0) < delta) &
                    @intFromBool(delta < splat(f32, 180))) != splat(u1, 0);
                const neg_180_zero_cond = (@intFromBool(splat(f32, -180) < delta) &
                    @intFromBool(delta <= splat(f32, 0))) != splat(u1, 0);
                a_mul_h = @select(f32, zero_180_cond, a_mul_h + splat(f32, 360), a_mul_h);
                b_mul_h = @select(f32, neg_180_zero_cond, b_mul_h + splat(f32, 360), b_mul_h);
            },
            .increasing => {
                const lt_cond = b_mul_h < a_mul_h;
                b_mul_h = @select(f32, lt_cond, b_mul_h + splat(f32, 360), b_mul_h);
            },
            .decreasing => {
                const lt_cond = a_mul_h < b_mul_h;
                a_mul_h = @select(f32, lt_cond, a_mul_h + splat(f32, 360), a_mul_h);
            },
        }

        const h_result = lerpPolar(a_mul.h, a_mul_h, b_mul_h, t);
        return demultiplyVec(HSL.Vector{
            .h = @mod(h_result, splat(f32, 360)),
            .s = lerp(a_mul.s, b_mul.s, t),
            .l = lerp(a_mul.l, b_mul.l, t),
            .a = lerp(a_mul.a, b_mul.a, t),
        });
    }

    /// Performs standard linear interpolation and returns the value as an
    /// encoded, pre-multiplied RGBA value.
    pub fn interpolateEncode(a: HSL, b: HSL, t: f32, method: InterpolationMethod.Polar) pixel.RGBA {
        return LinearRGB.encodeRGBARaw(interpolate(a, b, t, method).toRGB()).multiply();
    }

    /// Like interpolateEncode, but runs on vectors.
    fn interpolateEncodeVec(
        a: HSL.Vector,
        b: HSL.Vector,
        t: @Vector(vector_length, f32),
        method: InterpolationMethod.Polar,
    ) vectorize(pixel.RGBA) {
        return LinearRGB.encodeRGBAVec(toRGBVec(interpolateVec(a, b, t, method)));
    }
};

/// Internal linear interpolation function used for color processing.
fn lerp(a: anytype, b: anytype, t: anytype) @TypeOf(a, b) {
    return a + (b - a) * t;
}

/// Internal linear interpolation function used for polar values.
fn lerpPolar(a: anytype, b: anytype, c: anytype, t: anytype) @TypeOf(a, b, c) {
    return a + (c - b) * t;
}

test "Color.init" {
    const name = "Color.init";
    const cases = [_]struct {
        name: []const u8,
        expected: Color,
        args: Color.InitArgs,
    }{
        .{
            .name = "rgb",
            .expected = LinearRGB.init(0.25, 0.5, 0.75, 1).asColor(),
            .args = .{ .rgb = .{ 0.25, 0.5, 0.75 } },
        },
        .{
            .name = "rgba",
            .expected = LinearRGB.init(0.25, 0.5, 0.75, 0.9).asColor(),
            .args = .{ .rgba = .{ 0.25, 0.5, 0.75, 0.9 } },
        },
        .{
            .name = "srgb",
            .expected = SRGB.init(0.25, 0.5, 0.75, 1).asColor(),
            .args = .{ .srgb = .{ 0.25, 0.5, 0.75 } },
        },
        .{
            .name = "srgba",
            .expected = SRGB.init(0.25, 0.5, 0.75, 0.9).asColor(),
            .args = .{ .srgba = .{ 0.25, 0.5, 0.75, 0.9 } },
        },
        .{
            .name = "hsl",
            .expected = HSL.init(180, 1, 0.5, 1).asColor(),
            .args = .{ .hsl = .{ 180, 1, 0.5 } },
        },
        .{
            .name = "hsla",
            .expected = HSL.init(180, 1, 0.5, 0.9).asColor(),
            .args = .{ .hsla = .{ 180, 1, 0.5, 0.9 } },
        },
        .{
            .name = "existing color",
            .expected = HSL.init(180, 1, 0.5, 0.9).asColor(),
            .args = .{ .color = Color.init(.{ .hsla = .{ 180, 1, 0.5, 0.9 } }) },
        },
    };
    const TestFn = struct {
        fn f(tc: anytype) TestingError!void {
            try testing.expectEqualDeep(tc.expected, Color.init(tc.args));
        }
    };
    try runCases(name, cases, TestFn.f);
}

test "LinearRGB.init" {
    {
        // Basic
        const got = LinearRGB.init(0.25, 0.5, 0.75, 1);
        const expected: LinearRGB = .{
            .r = 0.25,
            .g = 0.5,
            .b = 0.75,
            .a = 1,
        };
        try testing.expectEqualDeep(expected, got);
    }

    {
        // Clamped
        const got = LinearRGB.init(1.25, -1.25, 2, -3);
        const expected: LinearRGB = .{
            .r = 1,
            .g = 0,
            .b = 1,
            .a = 0,
        };
        try testing.expectEqualDeep(expected, got);
    }
}

test "LinearRGB.fromColor" {
    {
        // From linear
        const got = LinearRGB.fromColor(LinearRGB.init(0.25, 0.5, 0.75, 1).asColor());
        const expected: LinearRGB = .{
            .r = 0.25,
            .g = 0.5,
            .b = 0.75,
            .a = 1,
        };
        try testing.expectEqualDeep(expected, got);
    }

    {
        // From gamma-corrected
        const got = LinearRGB.fromColor(SRGB.init(0.25, 0.5, 0.75, 1).asColor());
        const expected: LinearRGB = .{
            .r = math.pow(f32, 0.25, 2.2),
            .g = math.pow(f32, 0.5, 2.2),
            .b = math.pow(f32, 0.75, 2.2),
            .a = math.pow(f32, 1, 2.2),
        };
        try testing.expectEqualDeep(expected, got);
    }

    {
        // From HSL
        const got = LinearRGB.fromColor(HSL.init(0, 1, 0.5, 1).asColor());
        const expected: LinearRGB = .{
            .r = 1,
            .g = 0,
            .b = 0,
            .a = 1,
        };
        try testing.expectEqualDeep(expected, got);
    }
}

test "LinearRGB.fromColorVec" {
    // Simple test here designed to scale with vector_length, basically we do
    // Red in HSL, scaling on lightness from 0 - 0.5 in 1 / vector_length
    // intervals.
    var colors: [vector_length]Color = undefined;
    var expected: LinearRGB.Vector = undefined;
    for (0..vector_length) |i| {
        const j: f32 = @floatFromInt(i);
        const k: f32 = @floatFromInt(vector_length);
        colors[i] = HSL.init(0, 1, 0.5 * (1 / k * j), 1).asColor();
        expected.r[i] = 1 * (1 / k * j);
        expected.g[i] = 0;
        expected.b[i] = 0;
        expected.a[i] = 1;
    }
    const got = LinearRGB.fromColorVec(colors);
    try testing.expectEqualDeep(expected, got);
}

test "LinearRGB.decodeRGBA, LinearRGB.decodeRGBARaw" {
    // TODO: using pixel.RGBA's clamping for now (applies pre-multiplication
    // for us). I don't necessarily have plans to remove the direct
    // functionality in pixel just yet, and it helps assert behavior across
    // color and pixel helpers, but if/when we do (likely will happen
    // eventually) we should move this to a static test to assert, unless our
    // testing in multiply particularly asserts that round-tripping works just
    // fine.
    const px_rgba = pixel.RGBA.fromClamped(0.25, 0.5, 0.75, 0.9);
    const got = LinearRGB.decodeRGBA(px_rgba);
    const got_raw = LinearRGB.decodeRGBARaw(px_rgba);
    const expected: LinearRGB = .{
        .r = 0.25,
        .g = 0.5,
        .b = 0.75,
        .a = 0.9,
    };
    const expected_raw = expected.multiply();
    // Set our epsilon to help accommodate integer mul/demul error
    const epsilon: f32 = 1.0 / 128.0;
    try testing.expectApproxEqAbs(expected.r, got.r, epsilon);
    try testing.expectApproxEqAbs(expected.g, got.g, epsilon);
    try testing.expectApproxEqAbs(expected.b, got.b, epsilon);
    try testing.expectApproxEqAbs(expected.a, got.a, epsilon);
    try testing.expectApproxEqAbs(expected_raw.r, got_raw.r, epsilon);
    try testing.expectApproxEqAbs(expected_raw.g, got_raw.g, epsilon);
    try testing.expectApproxEqAbs(expected_raw.b, got_raw.b, epsilon);
    try testing.expectApproxEqAbs(expected_raw.a, got_raw.a, epsilon);
}

test "LinearRGB.encodeRGBA, LinearRGB.encodeRGBAVec, LinearRGB.encodeRGBARaw, LinearRGB.encodeRGBAVecRaw" {
    const in = LinearRGB.init(0.25, 0.5, 0.75, 0.9);
    var in_vec: LinearRGB.Vector = undefined;
    for (0..vector_length) |i| {
        in_vec.r[i] = in.r;
        in_vec.g[i] = in.g;
        in_vec.b[i] = in.b;
        in_vec.a[i] = in.a;
    }
    const got = LinearRGB.encodeRGBA(in);
    const got_vec = LinearRGB.encodeRGBAVec(in_vec);
    const got_raw = LinearRGB.encodeRGBARaw(in);
    const got_raw_vec = LinearRGB.encodeRGBAVecRaw(in_vec);
    const expected = pixel.RGBA.fromClamped(0.25, 0.5, 0.75, 0.9);
    var expected_vec: vectorize(pixel.RGBA) = undefined;
    for (0..vector_length) |i| {
        expected_vec.r[i] = expected.r;
        expected_vec.g[i] = expected.g;
        expected_vec.b[i] = expected.b;
        expected_vec.a[i] = expected.a;
    }
    const expected_raw: pixel.RGBA = .{
        .r = 64,
        .g = 128,
        .b = 191,
        .a = 230,
    };
    var expected_raw_vec: vectorize(pixel.RGBA) = undefined;
    for (0..vector_length) |i| {
        expected_raw_vec.r[i] = expected_raw.r;
        expected_raw_vec.g[i] = expected_raw.g;
        expected_raw_vec.b[i] = expected_raw.b;
        expected_raw_vec.a[i] = expected_raw.a;
    }
    try testing.expectEqualDeep(expected, got);
    try testing.expectEqualDeep(expected_vec, got_vec);
    try testing.expectEqualDeep(expected_raw, got_raw);
    try testing.expectEqualDeep(expected_raw_vec, got_raw_vec);
}

test "LinearRGB.multiply" {
    const got = LinearRGB.init(0.25, 0.5, 0.75, 0.9).multiply();
    const expected: LinearRGB = .{
        .r = 0.225,
        .g = 0.45,
        .b = 0.675,
        .a = 0.9,
    };
    try testing.expectApproxEqAbs(expected.r, got.r, math.floatEps(f32));
    try testing.expectApproxEqAbs(expected.g, got.g, math.floatEps(f32));
    try testing.expectApproxEqAbs(expected.b, got.b, math.floatEps(f32));
    try testing.expectApproxEqAbs(expected.a, got.a, math.floatEps(f32));
}

test "LinearRGB.demultiply" {
    const got = LinearRGB.init(0.225, 0.45, 0.675, 0.9).demultiply();
    const expected: LinearRGB = .{
        .r = 0.25,
        .g = 0.5,
        .b = 0.75,
        .a = 0.9,
    };
    try testing.expectApproxEqAbs(expected.r, got.r, math.floatEps(f32));
    try testing.expectApproxEqAbs(expected.g, got.g, math.floatEps(f32));
    try testing.expectApproxEqAbs(expected.b, got.b, math.floatEps(f32));
    try testing.expectApproxEqAbs(expected.a, got.a, math.floatEps(f32));
}

test "LinearRGB.removeGamma, LinearRGB.removeGammaVec" {
    const in = LinearRGB.init(0.25, 0.5, 0.75, 0.9);
    var in_vec: LinearRGB.Vector = undefined;
    for (0..vector_length) |i| {
        in_vec.r[i] = in.r;
        in_vec.g[i] = in.g;
        in_vec.b[i] = in.b;
        in_vec.a[i] = in.a;
    }
    const got = in.removeGamma();
    const got_vec = LinearRGB.removeGammaVec(in_vec);
    const expected: LinearRGB = .{
        .r = 0.25,
        .g = 0.5,
        .b = 0.75,
        .a = 0.9,
    };
    var expected_vec: LinearRGB.Vector = undefined;
    for (0..vector_length) |i| {
        expected_vec.r[i] = expected.r;
        expected_vec.g[i] = expected.g;
        expected_vec.b[i] = expected.b;
        expected_vec.a[i] = expected.a;
    }
    try testing.expectEqualDeep(expected, got);
    try testing.expectEqualDeep(expected_vec, got_vec);
}

test "LinearRGB.applyGamma" {
    const got = LinearRGB.init(0.25, 0.5, 0.75, 0.9).applyGamma();
    const expected: LinearRGB = .{
        .r = 0.25,
        .g = 0.5,
        .b = 0.75,
        .a = 0.9,
    };
    try testing.expectEqualDeep(expected, got);
}

test "LinearRGB.interpolate, LinearRGB.interpolateEncode" {
    const name = "LinearRGB.interpolate, LinearRGB.interpolateEncode";
    const red = LinearRGB.init(1, 0, 0, 0.9);
    const green = LinearRGB.init(0, 1, 0, 0.9);
    const blue = LinearRGB.init(0, 0, 1, 0.9);

    const cases = [_]struct {
        name: []const u8,
        expected: LinearRGB,
        a: LinearRGB,
        b: LinearRGB,
        t: f32,
    }{
        .{
            .name = "red to green, 0%",
            .expected = LinearRGB.init(1, 0, 0, 0.9),
            .a = red,
            .b = green,
            .t = 0.0,
        },
        .{
            .name = "red to green, 25%",
            .expected = LinearRGB.init(0.75, 0.25, 0, 0.9),
            .a = red,
            .b = green,
            .t = 0.25,
        },
        .{
            .name = "red to green, 50%",
            .expected = LinearRGB.init(0.5, 0.5, 0, 0.9),
            .a = red,
            .b = green,
            .t = 0.5,
        },
        .{
            .name = "red to green, 75%",
            .expected = LinearRGB.init(0.25, 0.75, 0, 0.9),
            .a = red,
            .b = green,
            .t = 0.75,
        },
        .{
            .name = "red to green, 100%",
            .expected = LinearRGB.init(0, 1, 0, 0.9),
            .a = red,
            .b = green,
            .t = 1,
        },
        .{
            .name = "green to blue, 0%",
            .expected = LinearRGB.init(0, 1, 0, 0.9),
            .a = green,
            .b = blue,
            .t = 0.0,
        },
        .{
            .name = "green to blue, 25%",
            .expected = LinearRGB.init(0, 0.75, 0.25, 0.9),
            .a = green,
            .b = blue,
            .t = 0.25,
        },
        .{
            .name = "green to blue, 50%",
            .expected = LinearRGB.init(0, 0.5, 0.5, 0.9),
            .a = green,
            .b = blue,
            .t = 0.5,
        },
        .{
            .name = "green to blue, 75%",
            .expected = LinearRGB.init(0, 0.25, 0.75, 0.9),
            .a = green,
            .b = blue,
            .t = 0.75,
        },
        .{
            .name = "green to blue, 100%",
            .expected = LinearRGB.init(0, 0, 1, 0.9),
            .a = green,
            .b = blue,
            .t = 1,
        },
    };
    const TestFn = struct {
        fn f(tc: anytype) TestingError!void {
            const got = LinearRGB.interpolate(tc.a, tc.b, tc.t);
            const got_rgba = LinearRGB.interpolateEncode(tc.a, tc.b, tc.t);
            const expected_rgba = tc.expected.encodeRGBA();
            try testing.expectApproxEqAbs(tc.expected.r, got.r, math.floatEps(f32));
            try testing.expectApproxEqAbs(tc.expected.g, got.g, math.floatEps(f32));
            try testing.expectApproxEqAbs(tc.expected.b, got.b, math.floatEps(f32));
            try testing.expectApproxEqAbs(tc.expected.a, got.a, math.floatEps(f32));
            try testing.expectEqualDeep(expected_rgba, got_rgba);
        }
    };
    try runCases(name, cases, TestFn.f);
}

test "LinearRGB.interpolateVec, LinearRGB.interpolateEncodeVec" {
    // Interpolation from red to green over the vector length.
    const red = LinearRGB.init(1, 0, 0, 0.9);
    const green = LinearRGB.init(0, 1, 0, 0.9);

    // Build params
    var red_vec: LinearRGB.Vector = undefined;
    var green_vec: LinearRGB.Vector = undefined;
    var t_vec: @Vector(vector_length, f32) = undefined;
    for (0..vector_length) |i| {
        red_vec.r[i] = red.r;
        red_vec.g[i] = red.g;
        red_vec.b[i] = red.b;
        red_vec.a[i] = red.a;
        green_vec.r[i] = green.r;
        green_vec.g[i] = green.g;
        green_vec.b[i] = green.b;
        green_vec.a[i] = green.a;
        const j: f32 = @floatFromInt(i);
        const k: f32 = @floatFromInt(vector_length);
        t_vec[i] = 1 / k * j;
    }

    // Build other params and expected RGBA set from interpolating individually
    var expected: LinearRGB.Vector = undefined;
    var expected_encoded: vectorize(pixel.RGBA) = undefined;
    for (0..vector_length) |i| {
        const expected_scalar = LinearRGB.interpolate(red, green, t_vec[i]);
        const expected_encoded_scalar = LinearRGB.interpolateEncode(red, green, t_vec[i]);
        expected.r[i] = expected_scalar.r;
        expected.g[i] = expected_scalar.g;
        expected.b[i] = expected_scalar.b;
        expected.a[i] = expected_scalar.a;
        expected_encoded.r[i] = expected_encoded_scalar.r;
        expected_encoded.g[i] = expected_encoded_scalar.g;
        expected_encoded.b[i] = expected_encoded_scalar.b;
        expected_encoded.a[i] = expected_encoded_scalar.a;
    }

    const got = LinearRGB.interpolateVec(red_vec, green_vec, t_vec);
    const got_encoded = LinearRGB.interpolateEncodeVec(red_vec, green_vec, t_vec);
    try testing.expectEqualDeep(expected, got);
    try testing.expectEqualDeep(expected_encoded, got_encoded);
}

test "SRGB.init" {
    {
        // Basic
        const got = SRGB.init(0.25, 0.5, 0.75, 1);
        const expected: SRGB = .{
            .r = 0.25,
            .g = 0.5,
            .b = 0.75,
            .a = 1,
        };
        try testing.expectEqualDeep(expected, got);
    }

    {
        // Clamped
        const got = SRGB.init(1.25, -1.25, 2, -3);
        const expected: SRGB = .{
            .r = 1,
            .g = 0,
            .b = 1,
            .a = 0,
        };
        try testing.expectEqualDeep(expected, got);
    }
}

test "SRGB.fromColor" {
    {
        // From linear
        const got = SRGB.fromColor(LinearRGB.init(0.25, 0.5, 0.75, 1).asColor());
        const expected: SRGB = .{
            .r = 0.5325205,
            .g = 0.7297400,
            .b = 0.8774243,
            .a = 1,
        };
        try testing.expectApproxEqAbs(expected.r, got.r, math.floatEps(f32));
        try testing.expectApproxEqAbs(expected.g, got.g, math.floatEps(f32));
        try testing.expectApproxEqAbs(expected.b, got.b, math.floatEps(f32));
        try testing.expectApproxEqAbs(expected.a, got.a, math.floatEps(f32));
    }

    {
        // From gamma-corrected
        const got = SRGB.fromColor(SRGB.init(0.25, 0.5, 0.75, 1).asColor());
        const expected: SRGB = .{
            .r = 0.25,
            .g = 0.5,
            .b = 0.75,
            .a = 1,
        };
        try testing.expectEqualDeep(expected, got);
    }

    {
        // From HSL
        const got = SRGB.fromColor(HSL.init(180, 1, 0.25, 1).asColor());
        const expected: SRGB = .{
            .r = 0,
            .g = 0.7297400,
            .b = 0.7297400,
            .a = 1,
        };
        try testing.expectApproxEqAbs(expected.r, got.r, math.floatEps(f32));
        try testing.expectApproxEqAbs(expected.g, got.g, math.floatEps(f32));
        try testing.expectApproxEqAbs(expected.b, got.b, math.floatEps(f32));
        try testing.expectApproxEqAbs(expected.a, got.a, math.floatEps(f32));
    }
}

test "SRGB.fromColorVec" {
    // Simple test here designed to scale with vector_length, basically we do
    // Red in HSL, scaling on lightness from 0 - 0.5 in 1 / vector_length
    // intervals.
    var colors: [vector_length]Color = undefined;
    var expected: SRGB.Vector = undefined;
    for (0..vector_length) |i| {
        const j: f32 = @floatFromInt(i);
        const k: f32 = @floatFromInt(vector_length);
        colors[i] = HSL.init(0, 1, 0.5 * (1 / k * j), 1).asColor();
        expected.r[i] = math.pow(f32, 1.0 * (1.0 / k * j), 1.0 / 2.2);
        expected.g[i] = 0;
        expected.b[i] = 0;
        expected.a[i] = 1;
    }
    const got = SRGB.fromColorVec(colors);
    for (0..vector_length) |i| {
        try testing.expectApproxEqAbs(expected.r[i], got.r[i], math.floatEps(f32));
        try testing.expectApproxEqAbs(expected.g[i], got.g[i], math.floatEps(f32));
        try testing.expectApproxEqAbs(expected.b[i], got.b[i], math.floatEps(f32));
        try testing.expectApproxEqAbs(expected.a[i], got.a[i], math.floatEps(f32));
    }
}

test "SRGB.decodeRGBA, SRGB.decodeRGBARaw" {
    // TODO: using pixel.RGBA's clamping for now (applies pre-multiplication
    // for us). I don't necessarily have plans to remove the direct
    // functionality in pixel just yet, and it helps assert behavior across
    // color and pixel helpers, but if/when we do (likely will happen
    // eventually) we should move this to a static test to assert, unless our
    // testing in multiply particularly asserts that round-tripping works just
    // fine.
    const px_rgba = pixel.RGBA.fromClamped(0.25, 0.5, 0.75, 0.9);
    const got = SRGB.decodeRGBA(px_rgba);
    const got_raw = SRGB.decodeRGBARaw(px_rgba);
    const expected: SRGB = .{
        .r = 0.5296636,
        .g = 0.7284379,
        .b = 0.87481296,
        .a = 0.9019608,
    };
    const expected_raw = (SRGB{
        .r = 0.22352941,
        .g = 0.4509804,
        .b = 0.6745098,
        .a = 0.9019608,
    });
    try testing.expectEqualDeep(expected, got);
    try testing.expectEqualDeep(expected_raw, got_raw);
}

test "SRGB.encodeRGBA, LinearRGB.encodeRGBAVec, SRGB.encodeRGBARaw, SRGB.encodeRGBAVecRaw" {
    const in = SRGB.init(0.5296636, 0.7284379, 0.87481296, 0.9019608);
    var in_vec: SRGB.Vector = undefined;
    for (0..vector_length) |i| {
        in_vec.r[i] = in.r;
        in_vec.g[i] = in.g;
        in_vec.b[i] = in.b;
        in_vec.a[i] = in.a;
    }
    const got = SRGB.encodeRGBA(in);
    const got_vec = SRGB.encodeRGBAVec(in_vec);
    const got_raw = SRGB.encodeRGBARaw(in);
    const got_raw_vec = SRGB.encodeRGBAVecRaw(in_vec);
    const expected: pixel.RGBA = .{
        .r = 56,
        .g = 114,
        .b = 171,
        .a = 230,
    };
    var expected_vec: vectorize(pixel.RGBA) = undefined;
    for (0..vector_length) |i| {
        expected_vec.r[i] = expected.r;
        expected_vec.g[i] = expected.g;
        expected_vec.b[i] = expected.b;
        expected_vec.a[i] = expected.a;
    }
    const expected_raw: pixel.RGBA = .{
        .r = 135,
        .g = 186,
        .b = 223,
        .a = 230,
    };
    var expected_raw_vec: vectorize(pixel.RGBA) = undefined;
    for (0..vector_length) |i| {
        expected_raw_vec.r[i] = expected_raw.r;
        expected_raw_vec.g[i] = expected_raw.g;
        expected_raw_vec.b[i] = expected_raw.b;
        expected_raw_vec.a[i] = expected_raw.a;
    }
    try testing.expectEqualDeep(expected, got);
    try testing.expectEqualDeep(expected_vec, got_vec);
    try testing.expectEqualDeep(expected_raw, got_raw);
    try testing.expectEqualDeep(expected_raw_vec, got_raw_vec);
}

test "SRGB.multiply" {
    const got = SRGB.init(0.25, 0.5, 0.75, 0.9).multiply();
    const expected: SRGB = .{
        .r = 0.225,
        .g = 0.45,
        .b = 0.675,
        .a = 0.9,
    };
    try testing.expectApproxEqAbs(expected.r, got.r, math.floatEps(f32));
    try testing.expectApproxEqAbs(expected.g, got.g, math.floatEps(f32));
    try testing.expectApproxEqAbs(expected.b, got.b, math.floatEps(f32));
    try testing.expectApproxEqAbs(expected.a, got.a, math.floatEps(f32));
}

test "SRGB.demultiply" {
    const got = SRGB.init(0.225, 0.45, 0.675, 0.9).demultiply();
    const expected: SRGB = .{
        .r = 0.25,
        .g = 0.5,
        .b = 0.75,
        .a = 0.9,
    };
    try testing.expectApproxEqAbs(expected.r, got.r, math.floatEps(f32));
    try testing.expectApproxEqAbs(expected.g, got.g, math.floatEps(f32));
    try testing.expectApproxEqAbs(expected.b, got.b, math.floatEps(f32));
    try testing.expectApproxEqAbs(expected.a, got.a, math.floatEps(f32));
}

test "SRGB.removeGamma, SRGB.removeGammaVec" {
    const in = SRGB.init(0.25, 0.5, 0.75, 0.9);
    var in_vec: SRGB.Vector = undefined;
    for (0..vector_length) |i| {
        in_vec.r[i] = in.r;
        in_vec.g[i] = in.g;
        in_vec.b[i] = in.b;
        in_vec.a[i] = in.a;
    }
    const got = in.removeGamma();
    const got_vec = SRGB.removeGammaVec(in_vec);
    const expected: SRGB = .{
        .r = 0.047366142,
        .g = 0.21763763,
        .b = 0.53104925,
        .a = 0.9,
    };
    var expected_vec: SRGB.Vector = undefined;
    for (0..vector_length) |i| {
        expected_vec.r[i] = expected.r;
        expected_vec.g[i] = expected.g;
        expected_vec.b[i] = expected.b;
        expected_vec.a[i] = expected.a;
    }
    try testing.expectEqualDeep(expected, got);
    try testing.expectEqualDeep(expected_vec, got_vec);
}

test "SRGB.applyGamma" {
    const got = SRGB.init(0.25, 0.5, 0.75, 0.9).applyGamma();
    const expected: SRGB = .{
        .r = 0.5325205,
        .g = 0.7297400,
        .b = 0.8774243,
        .a = 0.9,
    };
    try testing.expectApproxEqAbs(expected.r, got.r, math.floatEps(f32));
    try testing.expectApproxEqAbs(expected.g, got.g, math.floatEps(f32));
    try testing.expectApproxEqAbs(expected.b, got.b, math.floatEps(f32));
    try testing.expectApproxEqAbs(expected.a, got.a, math.floatEps(f32));
}

test "SRGB.interpolate, SRGB.interpolateEncode" {
    const name = "SRGB.interpolate, SRGB.interpolateEncode";
    const red = SRGB.init(1, 0, 0, 0.9);
    const green = SRGB.init(0, 1, 0, 0.9);
    const blue = SRGB.init(0, 0, 1, 0.9);

    const cases = [_]struct {
        name: []const u8,
        expected: SRGB,
        a: SRGB,
        b: SRGB,
        t: f32,
    }{
        .{
            .name = "red to green, 0%",
            .expected = SRGB.init(1, 0, 0, 0.9),
            .a = red,
            .b = green,
            .t = 0.0,
        },
        .{
            .name = "red to green, 25%",
            .expected = SRGB.init(0.75, 0.25, 0, 0.9),
            .a = red,
            .b = green,
            .t = 0.25,
        },
        .{
            .name = "red to green, 50%%",
            .expected = SRGB.init(0.5, 0.5, 0, 0.9),
            .a = red,
            .b = green,
            .t = 0.5,
        },
        .{
            .name = "red to green, 75%",
            .expected = SRGB.init(0.25, 0.75, 0, 0.9),
            .a = red,
            .b = green,
            .t = 0.75,
        },
        .{
            .name = "red to green, 100%",
            .expected = SRGB.init(0, 1, 0, 0.9),
            .a = red,
            .b = green,
            .t = 1,
        },
        .{
            .name = "green to blue, 0%",
            .expected = SRGB.init(0, 1, 0, 0.9),
            .a = green,
            .b = blue,
            .t = 0.0,
        },
        .{
            .name = "green to blue, 25%",
            .expected = SRGB.init(0, 0.75, 0.25, 0.9),
            .a = green,
            .b = blue,
            .t = 0.25,
        },
        .{
            .name = "green to blue, 50%",
            .expected = SRGB.init(0, 0.5, 0.5, 0.9),
            .a = green,
            .b = blue,
            .t = 0.5,
        },
        .{
            .name = "green to blue, 75%",
            .expected = SRGB.init(0, 0.25, 0.75, 0.9),
            .a = green,
            .b = blue,
            .t = 0.75,
        },
        .{
            .name = "green to blue, 100%",
            .expected = SRGB.init(0, 0, 1, 0.9),
            .a = green,
            .b = blue,
            .t = 1,
        },
    };
    const TestFn = struct {
        fn f(tc: anytype) TestingError!void {
            const got = SRGB.interpolate(tc.a, tc.b, tc.t);
            // NOTE: This is a good demonstration of how interpolating in sRGB
            // can cause issues; our RGB interpolation functionality
            // intentionally does not convert back to linear space before
            // writing out pixels (as it does not de-multiply first, which
            // would be an essential step here). This is essentially the same
            // as *encoding* non-linear sRGB as its gamma-corrected value with
            // the alpha pre-multiplied, and as such this is not recommended
            // for use in the library. We explicitly (currently) do not allow
            // interpolation in non-linear RGB in InterpolationMethod for this
            // reason.
            const got_rgba = SRGB.interpolateEncode(tc.a, tc.b, tc.t);
            const expected_rgba = SRGB.encodeRGBARaw(tc.expected.multiply());
            try testing.expectApproxEqAbs(tc.expected.r, got.r, math.floatEps(f32));
            try testing.expectApproxEqAbs(tc.expected.g, got.g, math.floatEps(f32));
            try testing.expectApproxEqAbs(tc.expected.b, got.b, math.floatEps(f32));
            try testing.expectApproxEqAbs(tc.expected.a, got.a, math.floatEps(f32));
            try testing.expectEqualDeep(expected_rgba, got_rgba);
        }
    };
    try runCases(name, cases, TestFn.f);
}

test "SRGB.interpolateEncodeVec" {
    // Interpolation from red to green over the vector length.
    const red = SRGB.init(1, 0, 0, 0.9);
    const green = SRGB.init(0, 1, 0, 0.9);

    // Build params
    var red_vec: SRGB.Vector = undefined;
    var green_vec: SRGB.Vector = undefined;
    var t_vec: @Vector(vector_length, f32) = undefined;
    for (0..vector_length) |i| {
        red_vec.r[i] = red.r;
        red_vec.g[i] = red.g;
        red_vec.b[i] = red.b;
        red_vec.a[i] = red.a;
        green_vec.r[i] = green.r;
        green_vec.g[i] = green.g;
        green_vec.b[i] = green.b;
        green_vec.a[i] = green.a;
        const j: f32 = @floatFromInt(i);
        const k: f32 = @floatFromInt(vector_length);
        t_vec[i] = 1 / k * j;
    }

    // Build other params and expected RGBA set from interpolating individually
    var expected: SRGB.Vector = undefined;
    var expected_encoded: vectorize(pixel.RGBA) = undefined;
    for (0..vector_length) |i| {
        const expected_scalar = SRGB.interpolate(red, green, t_vec[i]);
        const expected_encoded_scalar = SRGB.interpolateEncode(red, green, t_vec[i]);
        expected.r[i] = expected_scalar.r;
        expected.g[i] = expected_scalar.g;
        expected.b[i] = expected_scalar.b;
        expected.a[i] = expected_scalar.a;
        expected_encoded.r[i] = expected_encoded_scalar.r;
        expected_encoded.g[i] = expected_encoded_scalar.g;
        expected_encoded.b[i] = expected_encoded_scalar.b;
        expected_encoded.a[i] = expected_encoded_scalar.a;
    }

    const got = LinearRGB.interpolateVec(red_vec, green_vec, t_vec);
    const got_encoded = SRGB.interpolateEncodeVec(red_vec, green_vec, t_vec);
    try testing.expectEqualDeep(expected, got);
    try testing.expectEqualDeep(expected_encoded, got_encoded);
}

test "HSL.init" {
    {
        // Basic
        const got = HSL.init(180, 1, 0.5, 1);
        const expected: HSL = .{
            .h = 180,
            .s = 1,
            .l = 0.5,
            .a = 1,
        };
        try testing.expectEqualDeep(expected, got);
    }

    {
        // Exactly 360 degrees
        const got = HSL.init(360, 1, 0.5, 1);
        const expected: HSL = .{
            .h = 360,
            .s = 1,
            .l = 0.5,
            .a = 1,
        };
        try testing.expectEqualDeep(expected, got);
    }

    {
        // Clamped (above 360 degrees)
        const got = HSL.init(540, -1.25, 2.0, -3);
        const expected: HSL = .{
            .h = 180,
            .s = 0,
            .l = 1,
            .a = 0,
        };
        try testing.expectEqualDeep(expected, got);
    }

    {
        // Clamped (below 0 degrees)
        const got = HSL.init(-180, -1.25, 2.0, -3);
        const expected: HSL = .{
            .h = 180,
            .s = 0,
            .l = 1,
            .a = 0,
        };
        try testing.expectEqualDeep(expected, got);
    }
}

test "HSL.fromColor" {
    const name = "HSL.fromColor";
    const cases = [_]struct {
        name: []const u8,
        color: Color,
        expected: HSL,
    }{
        .{
            .name = "sRGB linear - cyan (half (0.25) lightness)",
            .color = LinearRGB.init(0, 0.5, 0.5, 1).asColor(),
            .expected = HSL.init(180, 1, 0.25, 1),
        },
        .{
            .name = "sRGB linear - red",
            .color = LinearRGB.init(1, 0, 0, 1).asColor(),
            .expected = HSL.init(0, 1, 0.5, 1),
        },
        .{
            .name = "sRGB linear - green",
            .color = LinearRGB.init(0, 1, 0, 1).asColor(),
            .expected = HSL.init(120, 1, 0.5, 1),
        },
        .{
            .name = "sRGB linear - blue",
            .color = LinearRGB.init(0, 0, 1, 1).asColor(),
            .expected = HSL.init(240, 1, 0.5, 1),
        },
        .{
            .name = "sRGB linear - navy blue",
            .color = LinearRGB.init(
                10.0 / 255.0,
                10.0 / 255.0,
                118.0 / 255.0,
                1,
            ).asColor(),
            .expected = HSL.init(240, 0.85, 0.25, 1),
        },
        .{
            .name = "sRGB default gamma - navy blue",
            .color = SRGB.init(
                math.pow(f32, 10.0 / 255.0, 1.0 / 2.2),
                math.pow(f32, 10.0 / 255.0, 1.0 / 2.2),
                math.pow(f32, 118.0 / 255.0, 1.0 / 2.2),
                1,
            ).asColor(),
            .expected = HSL.init(240, 0.85, 0.25, 1),
        },
        .{
            .name = "HSL (pass-through)",
            .color = HSL.init(240, 1, 0.5, 1).asColor(),
            .expected = HSL.init(240, 1, 0.5, 1),
        },
    };
    const TestFn = struct {
        fn f(tc: anytype) TestingError!void {
            const got = HSL.fromColor(tc.color);
            // We need an approximation match here due to precision loss when
            // converting from RGB; more complex colors won't come out exact.
            // 1/128 seems to be a good enough epsilon (I would not go higher).
            //
            // This should really have no effect on hue since it's stored in
            // degrees, and that fraction should be way too low to make a
            // difference.
            const epsilon: f32 = 1.0 / 128.0;
            inline for ("hsla") |field| {
                try testing.expectApproxEqAbs(
                    @field(tc.expected, &[_]u8{field}),
                    @field(got, &[_]u8{field}),
                    epsilon,
                );
            }
        }
    };
    try runCases(name, cases, TestFn.f);
}

test "HSL.fromColorVec" {
    // This the reverse of our fromColorVec tests for RGB, with a minor
    // modification (see below).
    var colors: [vector_length]Color = undefined;
    var expected: HSL.Vector = undefined;
    for (0..vector_length) |i| {
        // Bump j up so that it's 1-indexed versus 0-indexed, this ensures that
        // we don't actually init black (as we'll just get a zero-value HSL
        // back in that case).
        const j: f32 = @floatFromInt(i + 1);
        const k: f32 = @floatFromInt(vector_length);
        colors[i] = LinearRGB.init(1 * (1 / k * j), 0, 0, 1).asColor();
        expected.h[i] = 0;
        expected.s[i] = 1;
        expected.l[i] = 0.5 * (1 / k * j);
        expected.a[i] = 1;
    }
    const got = HSL.fromColorVec(colors);
    try testing.expectEqualDeep(expected, got);
}

test "HSL.fromRGB, zero value (black)" {
    // Asserts that we return zero values for pure black.
    //
    // NOTE: Other fromRGB tests are just handled in fromColor.
    try testing.expectEqualDeep(
        HSL.init(0, 0, 0, 1),
        HSL.fromRGB(LinearRGB.init(0, 0, 0, 1)),
    );
}

test "HSL.toRGB" {
    const got = HSL.toRGB(HSL.init(210, 0.5, 0.5, 1));
    const expected: LinearRGB = .{
        .r = 64.0 / 255.0,
        .g = 128.0 / 255.0,
        .b = 191.0 / 255.0,
        .a = 1,
    };
    const epsilon: f32 = 1.0 / 256.0; // small epsilon here to deal with rounding errors from converters
    try testing.expectApproxEqAbs(expected.r, got.r, epsilon);
    try testing.expectApproxEqAbs(expected.g, got.g, epsilon);
    try testing.expectApproxEqAbs(expected.b, got.b, epsilon);
    try testing.expectApproxEqAbs(expected.a, got.a, epsilon);
}

test "HSL.toSRGBVec" {
    // This is just the SRGBLinear.fromColorVec test for HSL -> SRGB, just with
    // the color unwrapped.
    var src_vec: HSL.Vector = undefined;
    var expected: LinearRGB.Vector = undefined;
    for (0..vector_length) |i| {
        const j: f32 = @floatFromInt(i);
        const k: f32 = @floatFromInt(vector_length);
        const src = HSL.init(0, 1, 0.5 * (1 / k * j), 1);
        src_vec.h[i] = src.h;
        src_vec.s[i] = src.s;
        src_vec.l[i] = src.l;
        src_vec.a[i] = src.a;
        expected.r[i] = 1 * (1 / k * j);
        expected.g[i] = 0;
        expected.b[i] = 0;
        expected.a[i] = 1;
    }
    const got = HSL.toRGBVec(src_vec);
    try testing.expectEqualDeep(expected, got);
}

test "HSL.multiply" {
    const got = HSL.init(240, 1, 0.5, 0.5).multiply();
    const expected: HSL = .{
        .h = 240,
        .s = 0.5,
        .l = 0.25,
        .a = 0.5,
    };
    try testing.expectApproxEqAbs(expected.h, got.h, math.floatEps(f32));
    try testing.expectApproxEqAbs(expected.s, got.s, math.floatEps(f32));
    try testing.expectApproxEqAbs(expected.l, got.l, math.floatEps(f32));
    try testing.expectApproxEqAbs(expected.a, got.a, math.floatEps(f32));
}

test "HSL.demultiply" {
    const got = HSL.init(240, 0.5, 0.25, 0.5).demultiply();
    const expected: HSL = .{
        .h = 240,
        .s = 1,
        .l = 0.5,
        .a = 0.5,
    };
    try testing.expectApproxEqAbs(expected.h, got.h, math.floatEps(f32));
    try testing.expectApproxEqAbs(expected.s, got.s, math.floatEps(f32));
    try testing.expectApproxEqAbs(expected.l, got.l, math.floatEps(f32));
    try testing.expectApproxEqAbs(expected.a, got.a, math.floatEps(f32));
}

test "HSL.interpolate, HSL.interpolateEncode" {
    const name = "HSL.interpolate, HSL.interpolateEncode";
    const red = HSL.init(0, 1, 0.5, 0.9);
    const green = HSL.init(120, 1, 0.5, 0.9);
    const cases = [_]struct {
        name: []const u8,
        expected: HSL,
        a: HSL,
        b: HSL,
        t: f32,
        method: InterpolationMethod.Polar,
    }{
        .{
            .name = "red to green, shorter, at start",
            .expected = HSL.init(0, 1, 0.5, 0.9),
            .a = red,
            .b = green,
            .method = .shorter,
            .t = 0.0,
        },
        .{
            .name = "red to green, shorter, at 25%",
            .expected = HSL.init(30, 1, 0.5, 0.9),
            .a = red,
            .b = green,
            .method = .shorter,
            .t = 0.25,
        },
        .{
            .name = "red to green, shorter, at 50%",
            .expected = HSL.init(60, 1, 0.5, 0.9),
            .a = red,
            .b = green,
            .method = .shorter,
            .t = 0.5,
        },
        .{
            .name = "red to green, shorter, at 100%",
            .expected = HSL.init(120, 1, 0.5, 0.9),
            .a = red,
            .b = green,
            .method = .shorter,
            .t = 1,
        },
        .{
            .name = "red to green, longer, at start",
            .expected = HSL.init(0, 1, 0.5, 0.9),
            .a = red,
            .b = green,
            .method = .longer,
            .t = 0.0,
        },
        .{
            .name = "red to green, longer, at 25%",
            .expected = HSL.init(300, 1, 0.5, 0.9),
            .a = red,
            .b = green,
            .method = .longer,
            .t = 0.25,
        },
        .{
            .name = "red to green, longer, at 50%",
            .expected = HSL.init(240, 1, 0.5, 0.9),
            .a = red,
            .b = green,
            .method = .longer,
            .t = 0.5,
        },
        .{
            .name = "red to green, longer, at 100%",
            .expected = HSL.init(120, 1, 0.5, 0.9),
            .a = red,
            .b = green,
            .method = .longer,
            .t = 1,
        },
        .{
            .name = "red to green, increasing, at start",
            .expected = HSL.init(0, 1, 0.5, 0.9),
            .a = red,
            .b = green,
            .method = .increasing,
            .t = 0.0,
        },
        .{
            .name = "red to green, increasing, at 25%",
            .expected = HSL.init(30, 1, 0.5, 0.9),
            .a = red,
            .b = green,
            .method = .increasing,
            .t = 0.25,
        },
        .{
            .name = "red to green, increasing, at 50%",
            .expected = HSL.init(60, 1, 0.5, 0.9),
            .a = red,
            .b = green,
            .method = .increasing,
            .t = 0.5,
        },
        .{
            .name = "red to green, increasing, at 100%",
            .expected = HSL.init(120, 1, 0.5, 0.9),
            .a = red,
            .b = green,
            .method = .increasing,
            .t = 1,
        },
        .{
            .name = "red to green, decreasing, at start",
            .expected = HSL.init(0, 1, 0.5, 0.9),
            .a = red,
            .b = green,
            .method = .decreasing,
            .t = 0.0,
        },
        .{
            .name = "red to green, decreasing, at 25%",
            .expected = HSL.init(300, 1, 0.5, 0.9),
            .a = red,
            .b = green,
            .method = .decreasing,
            .t = 0.25,
        },
        .{
            .name = "red to green, decreasing, at 50%",
            .expected = HSL.init(240, 1, 0.5, 0.9),
            .a = red,
            .b = green,
            .method = .decreasing,
            .t = 0.5,
        },
        .{
            .name = "red to green, decreasing, at 100%",
            .expected = HSL.init(120, 1, 0.5, 0.9),
            .a = red,
            .b = green,
            .method = .decreasing,
            .t = 1,
        },
        .{
            .name = "shorter path, clockwise over end of circle",
            .expected = HSL.init(22.5, 1, 0.5, 1),
            .a = HSL.init(300, 1, 0.5, 1),
            .b = HSL.init(50, 1, 0.5, 1),
            .method = .shorter,
            .t = 0.75,
        },
        .{
            // This is from the CSS color module as a test for LCH with alpha,
            // but as it's a polar space, the logic is the same.
            .name = "interpolating with alpha",
            .expected = HSL.init(31.820007, 0.81126004, 0.5887201, 0.5),
            .a = HSL.init(85.94, 0.6879, 0.6693, 0.4),
            .b = HSL.init(337.7, 0.8935, 0.535, 0.6),
            .method = .shorter,
            .t = 0.5,
        },
        .{
            .name = "increasing path, 0 to 360 degrees",
            .expected = HSL.init(180, 1, 0.5, 1),
            .a = HSL.init(0, 1, 0.5, 1),
            .b = HSL.init(360, 1, 0.5, 1),
            .method = .increasing,
            .t = 0.5,
        },
    };
    const TestFn = struct {
        fn f(tc: anytype) TestingError!void {
            const got = HSL.interpolate(tc.a, tc.b, tc.t, tc.method);
            const got_rgba = HSL.interpolateEncode(tc.a, tc.b, tc.t, tc.method);
            const expected_rgba = tc.expected.toRGB().encodeRGBA();
            try testing.expectEqualDeep(tc.expected, got);
            // try testing.expectApproxEqAbs(tc.expected.h, got.h, math.floatEps(f32));
            // try testing.expectApproxEqAbs(tc.expected.s, got.s, math.floatEps(f32));
            // try testing.expectApproxEqAbs(tc.expected.l, got.l, math.floatEps(f32));
            // try testing.expectApproxEqAbs(tc.expected.a, got.a, math.floatEps(f32));
            try testing.expectEqualDeep(expected_rgba, got_rgba);
        }
    };
    try runCases(name, cases, TestFn.f);
}

test "HSL.interpolateEncodeVec" {
    // Interpolation from red to blue over the vector length.
    const red = HSL.init(0, 1, 0.5, 0.9);
    const blue = HSL.init(240, 1, 0.5, 0.9);

    // Build params
    var red_vec: HSL.Vector = undefined;
    var blue_vec: HSL.Vector = undefined;
    var t_vec: @Vector(vector_length, f32) = undefined;
    for (0..vector_length) |i| {
        red_vec.h[i] = red.h;
        red_vec.s[i] = red.s;
        red_vec.l[i] = red.l;
        red_vec.a[i] = red.a;
        blue_vec.h[i] = blue.h;
        blue_vec.s[i] = blue.s;
        blue_vec.l[i] = blue.l;
        blue_vec.a[i] = blue.a;
        const j: f32 = @floatFromInt(i);
        const k: f32 = @floatFromInt(vector_length);
        t_vec[i] = 1 / k * j;
    }

    // Build other params and expected RGBA set from interpolating individually
    var expected_short: vectorize(pixel.RGBA) = undefined;
    var expected_long: vectorize(pixel.RGBA) = undefined;
    var expected_cw: vectorize(pixel.RGBA) = undefined;
    var expected_ccw: vectorize(pixel.RGBA) = undefined;
    for (0..vector_length) |i| {
        const expected_scalar_short = HSL.interpolateEncode(red, blue, t_vec[i], .shorter);
        const expected_scalar_long = HSL.interpolateEncode(red, blue, t_vec[i], .longer);
        const expected_scalar_cw = HSL.interpolateEncode(red, blue, t_vec[i], .increasing);
        const expected_scalar_ccw = HSL.interpolateEncode(red, blue, t_vec[i], .decreasing);
        expected_short.r[i] = expected_scalar_short.r;
        expected_short.g[i] = expected_scalar_short.g;
        expected_short.b[i] = expected_scalar_short.b;
        expected_short.a[i] = expected_scalar_short.a;
        expected_long.r[i] = expected_scalar_long.r;
        expected_long.g[i] = expected_scalar_long.g;
        expected_long.b[i] = expected_scalar_long.b;
        expected_long.a[i] = expected_scalar_long.a;
        expected_cw.r[i] = expected_scalar_cw.r;
        expected_cw.g[i] = expected_scalar_cw.g;
        expected_cw.b[i] = expected_scalar_cw.b;
        expected_cw.a[i] = expected_scalar_cw.a;
        expected_ccw.r[i] = expected_scalar_ccw.r;
        expected_ccw.g[i] = expected_scalar_ccw.g;
        expected_ccw.b[i] = expected_scalar_ccw.b;
        expected_ccw.a[i] = expected_scalar_ccw.a;
    }

    const got_short = HSL.interpolateEncodeVec(red_vec, blue_vec, t_vec, .shorter);
    const got_long = HSL.interpolateEncodeVec(red_vec, blue_vec, t_vec, .longer);
    const got_cw = HSL.interpolateEncodeVec(red_vec, blue_vec, t_vec, .increasing);
    const got_ccw = HSL.interpolateEncodeVec(red_vec, blue_vec, t_vec, .decreasing);
    try testing.expectEqualDeep(expected_short, got_short);
    try testing.expectEqualDeep(expected_long, got_long);
    try testing.expectEqualDeep(expected_cw, got_cw);
    try testing.expectEqualDeep(expected_ccw, got_ccw);
}

test "InterpolationMethod.interpolate, InterpolationMethod.interpolateEncode" {
    const name = "InterpolationMethod.interpolate, InterpolationMethod.interpolateEncode";
    const cases = [_]struct {
        name: []const u8,
        expected: Color,
        method: InterpolationMethod,
        a: Color,
        b: Color,
        t: f32,
    }{
        .{
            .name = ".linear_rgb, linear + linear",
            .method = .{ .linear_rgb = {} },
            .expected = LinearRGB.init(0.5, 0.5, 0, 1).asColor(),
            .a = LinearRGB.init(1, 0, 0, 1).asColor(),
            .b = LinearRGB.init(0, 1, 0, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".linear_rgb, HSL + linear",
            .method = .{ .linear_rgb = {} },
            .expected = LinearRGB.init(0.5, 0.5, 0, 1).asColor(),
            .a = HSL.init(0, 1, 0.5, 1).asColor(),
            .b = LinearRGB.init(0, 1, 0, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".linear_rgb, linear + HSL",
            .method = .{ .linear_rgb = {} },
            .expected = LinearRGB.init(0.5, 0.5, 0, 1).asColor(),
            .a = LinearRGB.init(1, 0, 0, 1).asColor(),
            .b = HSL.init(120, 1, 0.5, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".linear_rgb, HSL + HSL",
            .method = .{ .linear_rgb = {} },
            .expected = LinearRGB.init(0.5, 0.5, 0, 1).asColor(),
            .a = HSL.init(0, 1, 0.5, 1).asColor(),
            .b = HSL.init(120, 1, 0.5, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".linear_rgb, gamma + gamma",
            .method = .{ .linear_rgb = {} },
            // Expected here accommodates the f32 epsilon
            .expected = LinearRGB.init(0.24999996, 0.24999996, 0, 1).asColor(),
            .a = SRGB.init(math.pow(f32, 0.5, 1.0 / 2.2), 0, 0, 1).asColor(),
            .b = SRGB.init(0, math.pow(f32, 0.5, 1.0 / 2.2), 0, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".hsl, shorter, linear + linear",
            .method = .{ .hsl = .shorter },
            .expected = HSL.init(60, 1, 0.5, 1).asColor(),
            .a = LinearRGB.init(1, 0, 0, 1).asColor(),
            .b = LinearRGB.init(0, 1, 0, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".hsl, shorter, HSL + linear",
            .method = .{ .hsl = .shorter },
            .expected = HSL.init(60, 1, 0.5, 1).asColor(),
            .a = HSL.init(0, 1, 0.5, 1).asColor(),
            .b = LinearRGB.init(0, 1, 0, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".hsl, shorter, linear + HSL",
            .method = .{ .hsl = .shorter },
            .expected = HSL.init(60, 1, 0.5, 1).asColor(),
            .a = LinearRGB.init(1, 0, 0, 1).asColor(),
            .b = HSL.init(120, 1, 0.5, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".hsl, shorter, HSL + HSL",
            .method = .{ .hsl = .shorter },
            .expected = HSL.init(60, 1, 0.5, 1).asColor(),
            .a = HSL.init(0, 1, 0.5, 1).asColor(),
            .b = HSL.init(120, 1, 0.5, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".hsl, shorter, gamma + gamma",
            .method = .{ .hsl = .shorter },
            // Expected here accommodates the f32 epsilon
            .expected = HSL.init(60, 1, 0.24999996, 1).asColor(),
            .a = SRGB.init(math.pow(f32, 0.5, 1.0 / 2.2), 0, 0, 1).asColor(),
            .b = SRGB.init(0, math.pow(f32, 0.5, 1.0 / 2.2), 0, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".hsl, longer, linear + linear",
            .method = .{ .hsl = .longer },
            .expected = HSL.init(240, 1, 0.5, 1).asColor(),
            .a = LinearRGB.init(1, 0, 0, 1).asColor(),
            .b = LinearRGB.init(0, 1, 0, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".hsl, longer, HSL + linear",
            .method = .{ .hsl = .longer },
            .expected = HSL.init(240, 1, 0.5, 1).asColor(),
            .a = HSL.init(0, 1, 0.5, 1).asColor(),
            .b = LinearRGB.init(0, 1, 0, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".hsl, longer, linear + HSL",
            .method = .{ .hsl = .longer },
            .expected = HSL.init(240, 1, 0.5, 1).asColor(),
            .a = LinearRGB.init(1, 0, 0, 1).asColor(),
            .b = HSL.init(120, 1, 0.5, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".hsl, longer, HSL + HSL",
            .method = .{ .hsl = .longer },
            .expected = HSL.init(240, 1, 0.5, 1).asColor(),
            .a = HSL.init(0, 1, 0.5, 1).asColor(),
            .b = HSL.init(120, 1, 0.5, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".hsl, longer, gamma + gamma",
            .method = .{ .hsl = .longer },
            // Expected here accommodates the f32 epsilon
            .expected = HSL.init(240, 1, 0.24999996, 1).asColor(),
            .a = SRGB.init(math.pow(f32, 0.5, 1.0 / 2.2), 0, 0, 1).asColor(),
            .b = SRGB.init(0, math.pow(f32, 0.5, 1.0 / 2.2), 0, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".hsl, increasing, linear + linear",
            .method = .{ .hsl = .increasing },
            .expected = HSL.init(60, 1, 0.5, 1).asColor(),
            .a = LinearRGB.init(1, 0, 0, 1).asColor(),
            .b = LinearRGB.init(0, 1, 0, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".hsl, increasing, HSL + linear",
            .method = .{ .hsl = .increasing },
            .expected = HSL.init(60, 1, 0.5, 1).asColor(),
            .a = HSL.init(0, 1, 0.5, 1).asColor(),
            .b = LinearRGB.init(0, 1, 0, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".hsl, increasing, linear + HSL",
            .method = .{ .hsl = .increasing },
            .expected = HSL.init(60, 1, 0.5, 1).asColor(),
            .a = LinearRGB.init(1, 0, 0, 1).asColor(),
            .b = HSL.init(120, 1, 0.5, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".hsl, increasing, HSL + HSL",
            .method = .{ .hsl = .increasing },
            .expected = HSL.init(60, 1, 0.5, 1).asColor(),
            .a = HSL.init(0, 1, 0.5, 1).asColor(),
            .b = HSL.init(120, 1, 0.5, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".hsl, increasing, gamma + gamma",
            .method = .{ .hsl = .increasing },
            // Expected here accommodates the f32 epsilon
            .expected = HSL.init(60, 1, 0.24999996, 1).asColor(),
            .a = SRGB.init(math.pow(f32, 0.5, 1.0 / 2.2), 0, 0, 1).asColor(),
            .b = SRGB.init(0, math.pow(f32, 0.5, 1.0 / 2.2), 0, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".hsl, decreasing, linear + linear",
            .method = .{ .hsl = .decreasing },
            .expected = HSL.init(240, 1, 0.5, 1).asColor(),
            .a = LinearRGB.init(1, 0, 0, 1).asColor(),
            .b = LinearRGB.init(0, 1, 0, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".hsl, decreasing, HSL + linear",
            .method = .{ .hsl = .decreasing },
            .expected = HSL.init(240, 1, 0.5, 1).asColor(),
            .a = HSL.init(0, 1, 0.5, 1).asColor(),
            .b = LinearRGB.init(0, 1, 0, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".hsl, decreasing, linear + HSL",
            .method = .{ .hsl = .decreasing },
            .expected = HSL.init(240, 1, 0.5, 1).asColor(),
            .a = LinearRGB.init(1, 0, 0, 1).asColor(),
            .b = HSL.init(120, 1, 0.5, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".hsl, decreasing, HSL + HSL",
            .method = .{ .hsl = .decreasing },
            .expected = HSL.init(240, 1, 0.5, 1).asColor(),
            .a = HSL.init(0, 1, 0.5, 1).asColor(),
            .b = HSL.init(120, 1, 0.5, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".hsl, decreasing, gamma + gamma",
            .method = .{ .hsl = .decreasing },
            // Expected here accommodates the f32 epsilon
            .expected = HSL.init(240, 1, 0.24999996, 1).asColor(),
            .a = SRGB.init(math.pow(f32, 0.5, 1.0 / 2.2), 0, 0, 1).asColor(),
            .b = SRGB.init(0, math.pow(f32, 0.5, 1.0 / 2.2), 0, 1).asColor(),
            .t = 0.5,
        },
    };
    const TestFn = struct {
        fn f(tc: anytype) TestingError!void {
            const got = tc.method.interpolate(tc.a, tc.b, tc.t);
            const expected_rgba = LinearRGB.fromColor(tc.expected).encodeRGBA();
            const got_rgba = tc.method.interpolateEncode(tc.a, tc.b, tc.t);
            try testing.expectEqualDeep(tc.expected, got);
            try testing.expectEqualDeep(expected_rgba, got_rgba);
        }
    };
    try runCases(name, cases, TestFn.f);
}

test "InterpolationMethod.interpolateVec, InterpolationMethod.interpolateEncodeVec" {
    const name = "InterpolationMethod.interpolateVec, InterpolationMethod.interpolateEncodeVec";
    const cases = [_]struct {
        name: []const u8,
        method: InterpolationMethod,
        a: Color,
        b: Color,
        t: f32,
    }{
        .{
            .name = ".linear_rgb, linear + linear",
            .method = .{ .linear_rgb = {} },
            .a = LinearRGB.init(1, 0, 0, 1).asColor(),
            .b = LinearRGB.init(0, 1, 0, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".linear_rgb, HSL + linear",
            .method = .{ .linear_rgb = {} },
            .a = HSL.init(0, 1, 0.5, 1).asColor(),
            .b = LinearRGB.init(0, 1, 0, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".linear_rgb, linear + HSL",
            .method = .{ .linear_rgb = {} },
            .a = LinearRGB.init(1, 0, 0, 1).asColor(),
            .b = HSL.init(120, 1, 0.5, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".linear_rgb, HSL + HSL",
            .method = .{ .linear_rgb = {} },
            .a = HSL.init(0, 1, 0.5, 1).asColor(),
            .b = HSL.init(120, 1, 0.5, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".linear_rgb, gamma + gamma",
            .method = .{ .linear_rgb = {} },
            .a = SRGB.init(math.pow(f32, 0.5, 1.0 / 2.2), 0, 0, 1).asColor(),
            .b = SRGB.init(0, math.pow(f32, 0.5, 1.0 / 2.2), 0, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".hsl, shorter, linear + linear",
            .method = .{ .hsl = .shorter },
            .a = LinearRGB.init(1, 0, 0, 1).asColor(),
            .b = LinearRGB.init(0, 1, 0, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".hsl, shorter, HSL + linear",
            .method = .{ .hsl = .shorter },
            .a = HSL.init(0, 1, 0.5, 1).asColor(),
            .b = LinearRGB.init(0, 1, 0, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".hsl, shorter, linear + HSL",
            .method = .{ .hsl = .shorter },
            .a = LinearRGB.init(1, 0, 0, 1).asColor(),
            .b = HSL.init(120, 1, 0.5, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".hsl, shorter, HSL + HSL",
            .method = .{ .hsl = .shorter },
            .a = HSL.init(0, 1, 0.5, 1).asColor(),
            .b = HSL.init(120, 1, 0.5, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".hsl, shorter, gamma + gamma",
            .method = .{ .hsl = .shorter },
            .a = SRGB.init(math.pow(f32, 0.5, 1.0 / 2.2), 0, 0, 1).asColor(),
            .b = SRGB.init(0, math.pow(f32, 0.5, 1.0 / 2.2), 0, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".hsl, longer, linear + linear",
            .method = .{ .hsl = .longer },
            .a = LinearRGB.init(1, 0, 0, 1).asColor(),
            .b = LinearRGB.init(0, 1, 0, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".hsl, longer, HSL + linear",
            .method = .{ .hsl = .longer },
            .a = HSL.init(0, 1, 0.5, 1).asColor(),
            .b = LinearRGB.init(0, 1, 0, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".hsl, longer, linear + HSL",
            .method = .{ .hsl = .longer },
            .a = LinearRGB.init(1, 0, 0, 1).asColor(),
            .b = HSL.init(120, 1, 0.5, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".hsl, longer, HSL + HSL",
            .method = .{ .hsl = .longer },
            .a = HSL.init(0, 1, 0.5, 1).asColor(),
            .b = HSL.init(120, 1, 0.5, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".hsl, longer, gamma + gamma",
            .method = .{ .hsl = .longer },
            .a = SRGB.init(math.pow(f32, 0.5, 1.0 / 2.2), 0, 0, 1).asColor(),
            .b = SRGB.init(0, math.pow(f32, 0.5, 1.0 / 2.2), 0, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".hsl, increasing, linear + linear",
            .method = .{ .hsl = .increasing },
            .a = LinearRGB.init(1, 0, 0, 1).asColor(),
            .b = LinearRGB.init(0, 1, 0, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".hsl, increasing, HSL + linear",
            .method = .{ .hsl = .increasing },
            .a = HSL.init(0, 1, 0.5, 1).asColor(),
            .b = LinearRGB.init(0, 1, 0, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".hsl, increasing, linear + HSL",
            .method = .{ .hsl = .increasing },
            .a = LinearRGB.init(1, 0, 0, 1).asColor(),
            .b = HSL.init(120, 1, 0.5, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".hsl, increasing, HSL + HSL",
            .method = .{ .hsl = .increasing },
            .a = HSL.init(0, 1, 0.5, 1).asColor(),
            .b = HSL.init(120, 1, 0.5, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".hsl, increasing, gamma + gamma",
            .method = .{ .hsl = .increasing },
            .a = SRGB.init(math.pow(f32, 0.5, 1.0 / 2.2), 0, 0, 1).asColor(),
            .b = SRGB.init(0, math.pow(f32, 0.5, 1.0 / 2.2), 0, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".hsl, decreasing, linear + linear",
            .method = .{ .hsl = .decreasing },
            .a = LinearRGB.init(1, 0, 0, 1).asColor(),
            .b = LinearRGB.init(0, 1, 0, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".hsl, decreasing, HSL + linear",
            .method = .{ .hsl = .decreasing },
            .a = HSL.init(0, 1, 0.5, 1).asColor(),
            .b = LinearRGB.init(0, 1, 0, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".hsl, decreasing, linear + HSL",
            .method = .{ .hsl = .decreasing },
            .a = LinearRGB.init(1, 0, 0, 1).asColor(),
            .b = HSL.init(120, 1, 0.5, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".hsl, decreasing, HSL + HSL",
            .method = .{ .hsl = .decreasing },
            .a = HSL.init(0, 1, 0.5, 1).asColor(),
            .b = HSL.init(120, 1, 0.5, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".hsl, decreasing, gamma + gamma",
            .method = .{ .hsl = .decreasing },
            .a = SRGB.init(math.pow(f32, 0.5, 1.0 / 2.2), 0, 0, 1).asColor(),
            .b = SRGB.init(0, math.pow(f32, 0.5, 1.0 / 2.2), 0, 1).asColor(),
            .t = 0.5,
        },
    };
    const TestFn = struct {
        fn f(tc: anytype) TestingError!void {
            var a_vec: [vector_length]Color = undefined;
            var b_vec: [vector_length]Color = undefined;
            var t_vec: [vector_length]f32 = undefined;
            var expected: LinearRGB.Vector = undefined;
            var expected_encoded: vectorize(pixel.RGBA) = undefined;
            for (0..vector_length) |i| {
                a_vec[i] = tc.a;
                b_vec[i] = tc.b;
                const j: f32 = @floatFromInt(i);
                const k: f32 = @floatFromInt(vector_length);
                t_vec[i] = 1 / k * j;
                const expected_scalar = LinearRGB.fromColor(tc.method.interpolate(tc.a, tc.b, t_vec[i]));
                const expected_encoded_scalar = tc.method.interpolateEncode(tc.a, tc.b, t_vec[i]);
                expected.r[i] = expected_scalar.r;
                expected.g[i] = expected_scalar.g;
                expected.b[i] = expected_scalar.b;
                expected.a[i] = expected_scalar.a;
                expected_encoded.r[i] = expected_encoded_scalar.r;
                expected_encoded.g[i] = expected_encoded_scalar.g;
                expected_encoded.b[i] = expected_encoded_scalar.b;
                expected_encoded.a[i] = expected_encoded_scalar.a;
            }
            const got = tc.method.interpolateVec(a_vec, b_vec, t_vec);
            const got_encoded = tc.method.interpolateEncodeVec(a_vec, b_vec, t_vec);
            try testing.expectEqualDeep(expected, got);
            try testing.expectEqualDeep(expected_encoded, got_encoded);
        }
    };
    try runCases(name, cases, TestFn.f);
}
