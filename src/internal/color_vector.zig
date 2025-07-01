// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024-2025 Chris Marchesi

//! Internal vector types and helpers for color functionality.

const debug = @import("std").debug;
const math = @import("std").math;
const testing = @import("std").testing;

const color = @import("../color.zig");
const gradient = @import("../gradient.zig");
const pixel = @import("../pixel.zig");
const pixel_vector = @import("pixel_vector.zig");

const Dither = @import("../Dither.zig");

const gather = @import("util.zig").gather;
const splat = @import("util.zig").splat;
const vectorize = @import("util.zig").vectorize;
const runCases = @import("util.zig").runCases;
const TestingError = @import("util.zig").TestingError;

const vector_length = @import("../z2d.zig").vector_length;
const zero_float_vec = @import("util.zig").zero_float_vec;
const zero_color_vec = @import("util.zig").zero_color_vec;
const dither_blue_noise_64x64 = @import("blue_noise.zig").dither_blue_noise_64x64;

/// Vectorized version of `interpolate`. Designed for internal use by
/// the compositor; YMMV when using externally.
pub fn interpolateVec(
    method: color.InterpolationMethod,
    a: [vector_length]color.Color,
    b: [vector_length]color.Color,
    t: [vector_length]f32,
) LinearRGB.T {
    return switch (method) {
        .linear_rgb => LinearRGB.interpolateVec(
            LinearRGB.fromColorVec(a),
            LinearRGB.fromColorVec(b),
            t,
        ),
        // The main reason that interpolateVec exists is for dithering, which
        // expects linear space. So we need to add the additional step of
        // removing the gamma. After this we can just return without additional
        // coercion (this happens automatically).
        .srgb => SRGB.removeGammaVec(SRGB.interpolateVec(
            SRGB.fromColorVec(a),
            SRGB.fromColorVec(b),
            t,
        )),
        .hsl => |polar_method| HSL.toRGBVec(HSL.interpolateVec(
            HSL.fromColorVec(a),
            HSL.fromColorVec(b),
            t,
            polar_method,
        )),
    };
}

/// Vectorized version of `interpolateEncode`. Designed for internal use by
/// the compositor; YMMV when using externally.
pub fn interpolateEncodeVec(
    method: color.InterpolationMethod,
    a: [vector_length]color.Color,
    b: [vector_length]color.Color,
    t: [vector_length]f32,
) pixel_vector.RGBA16 {
    return switch (method) {
        .linear_rgb => LinearRGB.interpolateEncodeVec(
            LinearRGB.fromColorVec(a),
            LinearRGB.fromColorVec(b),
            t,
        ),
        .srgb => SRGB.interpolateEncodeVec(
            SRGB.fromColorVec(a),
            SRGB.fromColorVec(b),
            t,
        ),
        .hsl => |polar_method| HSL.interpolateEncodeVec(
            HSL.fromColorVec(a),
            HSL.fromColorVec(b),
            t,
            polar_method,
        ),
    };
}

/// Vectorized version of `getPixel`. Designed for internal use by the
/// compositor; YMMV when using externally.
pub fn fromDitherVecEncode(
    dither: *const Dither,
    x: i32,
    y: i32,
    comptime limit: bool,
    limit_len: usize,
) pixel_vector.RGBA16 {
    return LinearRGB.encodeRGBAVec(fromDitherVec(
        dither,
        x,
        y,
        limit,
        limit_len,
    ));
}

/// Vectorized color dithering. Designed for internal use by the compositor;
/// YMMV when using externally.
pub fn fromDitherVec(
    dither: *const Dither,
    x: i32,
    y: i32,
    comptime limit: bool,
    limit_len: usize,
) LinearRGB.T {
    if (limit) debug.assert(limit_len < vector_length);
    const rgba: LinearRGB.T = switch (dither.source) {
        .pixel => |src| c: {
            const c = color.LinearRGB.decodeRGBA(pixel.RGBA.fromPixel(src));
            break :c .{
                .r = @splat(c.r),
                .g = @splat(c.g),
                .b = @splat(c.b),
                .a = @splat(c.a),
            };
        },
        .color => |src| c: {
            const c = color.LinearRGB.fromColor(color.Color.init(src));
            break :c .{
                .r = @splat(c.r),
                .g = @splat(c.g),
                .b = @splat(c.b),
                .a = @splat(c.a),
            };
        },
        .gradient => |src| c: {
            var c0_vec: [vector_length]color.Color = zero_color_vec;
            var c1_vec: [vector_length]color.Color = zero_color_vec;
            var offsets_vec: [vector_length]f32 = zero_float_vec;
            for (0..vector_length) |i| {
                const search_result = src.searchInStops(src.getOffset(
                    x + @as(i32, @intCast(i)),
                    y,
                ));
                c0_vec[i] = search_result.c0;
                c1_vec[i] = search_result.c1;
                offsets_vec[i] = search_result.offset;
                if (limit) {
                    if (i + 1 == limit_len) break;
                }
            }
            break :c interpolateVec(
                src.getInterpolationMethod(),
                c0_vec,
                c1_vec,
                offsets_vec,
            );
        },
    };
    const m: @Vector(vector_length, f32) = switch (dither.type) {
        .none => return rgba,
        .bayer => mBayer8x8Vec(x, y),
        .blue_noise => mBlueNoise64x64Vec(x, y),
    };
    const scale = splat(f32, 1.0 / @as(
        f32,
        // Note: dither.scale being u4 limits this value to +65535
        // ((1 << 15) - 1)
        @floatFromInt((@as(i32, 1) << dither.scale) - 1),
    ));
    return .{
        .r = apply_dither(rgba.r, m, scale),
        .g = apply_dither(rgba.g, m, scale),
        .b = apply_dither(rgba.b, m, scale),
        .a = apply_dither(rgba.a, m, scale),
    };
}

fn apply_dither(
    value: @Vector(vector_length, f32),
    m: @Vector(vector_length, f32),
    scale: @Vector(vector_length, f32),
) @Vector(vector_length, f32) {
    const lower = splat(f32, 0.0);
    const upper = splat(f32, 1.0);
    return math.clamp(value + m * scale, lower, upper);
}

pub const LinearRGB = RGBVec(color.LinearRGB);
pub const SRGB = RGBVec(color.SRGB);

fn RGBVec(comptime underlying_T: type) type {
    return struct {
        pub const T = vectorize(underlying_T);

        /// Vectorizes a vector-sized array of colors translated to RGB,
        /// gamma-corrected.
        fn fromColorVec(src: [vector_length]color.Color) T {
            var result: T = undefined;
            for (src, 0..) |c, i| {
                const s = underlying_T.fromColor(c);
                result.r[i] = s.r;
                result.g[i] = s.g;
                result.b[i] = s.b;
                result.a[i] = s.a;
            }
            return result;
        }

        /// Vectorized version of applyGamma.
        pub fn applyGammaVec(src: T) T {
            if (underlying_T == color.LinearRGB) {
                return src;
            }
            // math.pow is not implemented for vectors, so we need to do this
            // element-by-element.
            var result: T = undefined;
            for (0..vector_length) |i| {
                result.r[i] = math.pow(f32, src.r[i], 1 / underlying_T.gamma);
                result.g[i] = math.pow(f32, src.g[i], 1 / underlying_T.gamma);
                result.b[i] = math.pow(f32, src.b[i], 1 / underlying_T.gamma);
                result.a[i] = src.a[i];
            }
            return result;
        }

        /// Vectorized version of removeGamma.
        fn removeGammaVec(src: T) T {
            if (underlying_T == color.LinearRGB) {
                return src;
            }
            // math.pow is not implemented for vectors, so we need to do this
            // element-by-element.
            var result: T = undefined;
            for (0..vector_length) |i| {
                result.r[i] = math.pow(f32, src.r[i], underlying_T.gamma);
                result.g[i] = math.pow(f32, src.g[i], underlying_T.gamma);
                result.b[i] = math.pow(f32, src.b[i], underlying_T.gamma);
                result.a[i] = src.a[i];
            }
            return result;
        }

        /// Vectorized version of encodeRGBA, used internally.
        fn encodeRGBAVec(src: T) pixel_vector.RGBA16 {
            // NOTE: we have other implementations of a 16-bit vectorized RGBA
            // value in the compositor package. I'm refraining from making that
            // public for the time being as this is currently the only case
            // where we need it outside of that package, but it's a possibility
            // if its use grows.
            const _src = if (underlying_T != color.LinearRGB)
                removeGammaVec(src)
            else
                src;

            const result: pixel_vector.RGBA16 = .{
                .r = @intFromFloat(@round(splat(f32, 255.0) * _src.r)),
                .g = @intFromFloat(@round(splat(f32, 255.0) * _src.g)),
                .b = @intFromFloat(@round(splat(f32, 255.0) * _src.b)),
                .a = @intFromFloat(@round(splat(f32, 255.0) * _src.a)),
            };
            return result.premultiply();
        }

        /// Like decodeRGBARaw, but converts vectorized RGBA pixel values to
        /// vectorized colors. Used internally.
        pub fn decodeRGBAVecRaw(src: pixel_vector.RGBA16) T {
            return .{
                .r = @as(@Vector(vector_length, f32), @floatFromInt(src.r)) / splat(f32, 255.0),
                .g = @as(@Vector(vector_length, f32), @floatFromInt(src.g)) / splat(f32, 255.0),
                .b = @as(@Vector(vector_length, f32), @floatFromInt(src.b)) / splat(f32, 255.0),
                .a = @as(@Vector(vector_length, f32), @floatFromInt(src.a)) / splat(f32, 255.0),
            };
        }

        /// Like encodeRGBARaw, but converts vectorized colors to vectorized RGBA
        /// values. Used internally.
        pub fn encodeRGBAVecRaw(src: T) pixel_vector.RGBA16 {
            return .{
                .r = @intFromFloat(@round(splat(f32, 255.0) * src.r)),
                .g = @intFromFloat(@round(splat(f32, 255.0) * src.g)),
                .b = @intFromFloat(@round(splat(f32, 255.0) * src.b)),
                .a = @intFromFloat(@round(splat(f32, 255.0) * src.a)),
            };
        }

        /// Internally-used vectorized version of multiply.
        fn multiplyVec(src: T) T {
            return .{
                .r = src.r * src.a,
                .g = src.g * src.a,
                .b = src.b * src.a,
                .a = src.a,
            };
        }

        /// Internally-used vectorized version of demultiply.
        fn demultiplyVec(src: T) T {
            return .{
                .r = @select(f32, src.a == splat(f32, 0), splat(f32, 0), src.r / src.a),
                .g = @select(f32, src.a == splat(f32, 0), splat(f32, 0), src.g / src.a),
                .b = @select(f32, src.a == splat(f32, 0), splat(f32, 0), src.b / src.a),
                .a = src.a,
            };
        }

        /// Internal interpolation function for vectors.
        fn interpolateVec(
            a: T,
            b: T,
            t: @Vector(vector_length, f32),
        ) T {
            const a_mul = multiplyVec(a);
            const b_mul = multiplyVec(b);
            const interpolated: T = .{
                .r = lerp(a_mul.r, b_mul.r, t),
                .g = lerp(a_mul.g, b_mul.g, t),
                .b = lerp(a_mul.b, b_mul.b, t),
                .a = lerp(a_mul.a, b_mul.a, t),
            };
            return demultiplyVec(interpolated);
        }

        /// Like interpolateEncode, but runs on vectors.
        fn interpolateEncodeVec(
            a: T,
            b: T,
            t: @Vector(vector_length, f32),
        ) pixel_vector.RGBA16 {
            const a_mul = multiplyVec(a);
            const b_mul = multiplyVec(b);
            const interpolated: T = .{
                .r = lerp(a_mul.r, b_mul.r, t),
                .g = lerp(a_mul.g, b_mul.g, t),
                .b = lerp(a_mul.b, b_mul.b, t),
                .a = lerp(a_mul.a, b_mul.a, t),
            };
            if (underlying_T == color.LinearRGB) {
                return encodeRGBAVecRaw(interpolated);
            }

            return encodeRGBAVec(demultiplyVec(interpolated));
        }
    };
}

pub const HSL = struct {
    pub const T = vectorize(color.HSL);

    /// Vectorizes a slice of colors translated to HSL.
    fn fromColorVec(src: [vector_length]color.Color) T {
        var result: T = undefined;
        for (src, 0..) |c, i| {
            const s = color.HSL.fromColor(c);
            result.h[i] = s.h;
            result.s[i] = s.s;
            result.l[i] = s.l;
            result.a[i] = s.a;
        }
        return result;
    }

    fn toRGBVec(src: T) LinearRGB.T {
        var hue = @rem(src.h, splat(f32, 360));
        hue = @select(f32, hue < splat(f32, 0), hue + splat(f32, 360), hue);

        return .{
            .r = toRGBChannelVec(splat(f32, 0), hue, src.s, src.l),
            .g = toRGBChannelVec(splat(f32, 8), hue, src.s, src.l),
            .b = toRGBChannelVec(splat(f32, 4), hue, src.s, src.l),
            .a = src.a,
        };
    }

    fn toRGBChannelVec(
        n: @Vector(vector_length, f32),
        hue: @Vector(vector_length, f32),
        sat: @Vector(vector_length, f32),
        light: @Vector(vector_length, f32),
    ) @Vector(vector_length, f32) {
        const k = @rem((n + hue / splat(f32, 30)), splat(f32, 12));
        const a = sat * @min(light, splat(f32, 1) - light);
        return light - a * @max(splat(f32, -1), @min(k - splat(f32, 3), splat(f32, 9) - k, splat(f32, 1)));
    }

    fn multiplyVec(src: T) T {
        return .{
            .h = src.h,
            .s = src.s * src.a,
            .l = src.l * src.a,
            .a = src.a,
        };
    }

    fn demultiplyVec(src: T) T {
        return .{
            .h = src.h,
            .s = @select(f32, src.a == splat(f32, 0), splat(f32, 0), src.s / src.a),
            .l = @select(f32, src.a == splat(f32, 0), splat(f32, 0), src.l / src.a),
            .a = src.a,
        };
    }

    /// Internal interpolation function for vectors.
    fn interpolateVec(
        a: T,
        b: T,
        t: @Vector(vector_length, f32),
        method: color.InterpolationMethod.Polar,
    ) T {
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
        return demultiplyVec(T{
            .h = @mod(h_result, splat(f32, 360)),
            .s = lerp(a_mul.s, b_mul.s, t),
            .l = lerp(a_mul.l, b_mul.l, t),
            .a = lerp(a_mul.a, b_mul.a, t),
        });
    }

    /// Like interpolateEncode, but runs on vectors.
    fn interpolateEncodeVec(
        a: T,
        b: T,
        t: @Vector(vector_length, f32),
        method: color.InterpolationMethod.Polar,
    ) pixel_vector.RGBA16 {
        return LinearRGB.encodeRGBAVec(toRGBVec(HSL.interpolateVec(a, b, t, method)));
    }
};

/// Internal linear interpolation function used for color processing.
fn lerp(
    a: @Vector(vector_length, f32),
    b: @Vector(vector_length, f32),
    t: @Vector(vector_length, f32),
) @Vector(vector_length, f32) {
    return a + (b - a) * t;
}

/// Internal linear interpolation function used for polar values.
fn lerpPolar(
    a: @Vector(vector_length, f32),
    b: @Vector(vector_length, f32),
    c: @Vector(vector_length, f32),
    t: @Vector(vector_length, f32),
) @Vector(vector_length, f32) {
    return a + (c - b) * t;
}

// Vectorized version of the virtual pre-calculated Bayer 8x8 matrix, just
// easier than a fully generic version.
fn mBayer8x8Vec(x: i32, y: i32) @Vector(vector_length, f32) {
    // Construct our x-vector
    var _x: @Vector(vector_length, i32) = undefined;
    for (0..vector_length) |i| _x[i] = x + @as(i32, @intCast(i));

    // Set up our xor-ed y-vector
    const _y = splat(i32, y) ^ _x;

    // Some literals cuz this is gonna get meaty
    const _x1 = splat(i32, 1);
    const _x2 = splat(i32, 2);
    const _x4 = splat(i32, 4);
    const sh5 = splat(u5, 5);
    const sh4 = splat(u5, 4);
    const sh2 = splat(u5, 2);
    const sh1 = splat(u5, 1);
    const _f2 = splat(f32, 2.0);
    const _f63 = splat(f32, 63.0);
    const _f128 = splat(f32, 128.0);

    const m: @Vector(vector_length, u32) = @intCast((_y & _x1) << sh5 | (_x & _x1) << sh4 |
        (_y & _x2) << sh2 | (_x & _x2) << sh1 |
        (_y & _x4) >> sh1 | (_x & _x4) >> sh2);
    return @as(@Vector(vector_length, f32), @floatFromInt(m)) * (_f2 / _f128) - (_f63 / _f128);
}

fn mBlueNoise64x64Vec(x: i32, y: i32) @Vector(vector_length, f32) {
    var _x: @Vector(vector_length, i32) = undefined;
    for (0..vector_length) |i| _x[i] = x + @as(i32, @intCast(i));
    const _y = splat(i32, y);

    const _i64 = splat(i32, 64);
    const sh6 = splat(u5, 6);
    const _f2 = splat(f32, 2.0);
    const _f4095 = splat(f32, 4095.0);
    const _f8192 = splat(f32, 8192.0);

    const idx: @Vector(vector_length, usize) = @intCast(@mod(_x, _i64) << sh6 | @mod(_y, _i64));
    const m = gather(@as([]const u16, @ptrCast(&dither_blue_noise_64x64)), idx);
    return @as(@Vector(vector_length, f32), @floatFromInt(m)) * (_f2 / _f8192) - (_f4095 / _f8192);
}

test "LinearRGB.fromColorVec" {
    // Simple test here designed to scale with vector_length, basically we do
    // Red in HSL, scaling on lightness from 0 - 0.5 in 1 / vector_length
    // intervals.
    var colors: [vector_length]color.Color = undefined;
    var expected: LinearRGB.T = undefined;
    for (0..vector_length) |i| {
        const j: f32 = @floatFromInt(i);
        const k: f32 = @floatFromInt(vector_length);
        colors[i] = color.HSL.init(0, 1, 0.5 * (1 / k * j), 1).asColor();
        expected.r[i] = 1 * (1 / k * j);
        expected.g[i] = 0;
        expected.b[i] = 0;
        expected.a[i] = 1;
    }
    const got = LinearRGB.fromColorVec(colors);
    try testing.expectEqualDeep(expected, got);
}

test "LinearRGB.decodeRGBAVecRaw" {
    // TODO: using pixel.RGBA's clamping for now (applies pre-multiplication
    // for us). I don't necessarily have plans to remove the direct
    // functionality in pixel just yet, and it helps assert behavior across
    // color and pixel helpers, but if/when we do (likely will happen
    // eventually) we should move this to a static test to assert, unless our
    // testing in multiply particularly asserts that round-tripping works just
    // fine.
    const px_rgba = pixel.RGBA.fromClamped(0.25, 0.5, 0.75, 0.9);
    var px_rgba_vec: pixel_vector.RGBA16 = undefined;
    for (0..vector_length) |i| {
        px_rgba_vec.r[i] = px_rgba.r;
        px_rgba_vec.g[i] = px_rgba.g;
        px_rgba_vec.b[i] = px_rgba.b;
        px_rgba_vec.a[i] = px_rgba.a;
    }
    const got_raw = color.LinearRGB.decodeRGBARaw(px_rgba);
    const got_raw_vec = LinearRGB.decodeRGBAVecRaw(px_rgba_vec);

    var expected_raw_vec: LinearRGB.T = undefined;
    for (0..vector_length) |i| {
        expected_raw_vec.r[i] = got_raw.r;
        expected_raw_vec.g[i] = got_raw.g;
        expected_raw_vec.b[i] = got_raw.b;
        expected_raw_vec.a[i] = got_raw.a;
    }

    try testing.expectEqualDeep(expected_raw_vec, got_raw_vec);
}

test "LinearRGB.encodeRGBAVec, LinearRGB.encodeRGBAVecRaw" {
    const in = color.LinearRGB.init(0.25, 0.5, 0.75, 0.9);
    var in_vec: LinearRGB.T = undefined;
    for (0..vector_length) |i| {
        in_vec.r[i] = in.r;
        in_vec.g[i] = in.g;
        in_vec.b[i] = in.b;
        in_vec.a[i] = in.a;
    }
    const got = color.LinearRGB.encodeRGBA(in);
    const got_vec = LinearRGB.encodeRGBAVec(in_vec);
    const got_raw = color.LinearRGB.encodeRGBARaw(in);
    const got_raw_vec = LinearRGB.encodeRGBAVecRaw(in_vec);
    var expected_vec: pixel_vector.RGBA16 = undefined;
    for (0..vector_length) |i| {
        expected_vec.r[i] = got.r;
        expected_vec.g[i] = got.g;
        expected_vec.b[i] = got.b;
        expected_vec.a[i] = got.a;
    }
    var expected_raw_vec: pixel_vector.RGBA16 = undefined;
    for (0..vector_length) |i| {
        expected_raw_vec.r[i] = got_raw.r;
        expected_raw_vec.g[i] = got_raw.g;
        expected_raw_vec.b[i] = got_raw.b;
        expected_raw_vec.a[i] = got_raw.a;
    }
    try testing.expectEqualDeep(expected_vec, got_vec);
    try testing.expectEqualDeep(expected_raw_vec, got_raw_vec);
}

test "LinearRGB.demultiplyVec, divide by zero" {
    // Note that we use this as a divide-by-zero check for all other generated
    // RGB profiles.
    const in: LinearRGB.T = .{
        .r = @splat(1),
        .g = @splat(0.75),
        .b = @splat(0.25),
        .a = @splat(0.0),
    };
    const got = LinearRGB.demultiplyVec(in);
    const expected: LinearRGB.T = .{
        .r = @splat(0.0),
        .g = @splat(0.0),
        .b = @splat(0.0),
        .a = @splat(0.0),
    };
    try testing.expectEqualDeep(expected, got);
}

test "LinearRGB.removeGammaVec" {
    const in = color.LinearRGB.init(0.25, 0.5, 0.75, 0.9);
    var in_vec: LinearRGB.T = undefined;
    for (0..vector_length) |i| {
        in_vec.r[i] = in.r;
        in_vec.g[i] = in.g;
        in_vec.b[i] = in.b;
        in_vec.a[i] = in.a;
    }
    const got = in.removeGamma();
    const got_vec = LinearRGB.removeGammaVec(in_vec);
    var expected_vec: LinearRGB.T = undefined;
    for (0..vector_length) |i| {
        expected_vec.r[i] = got.r;
        expected_vec.g[i] = got.g;
        expected_vec.b[i] = got.b;
        expected_vec.a[i] = got.a;
    }
    try testing.expectEqualDeep(expected_vec, got_vec);
}

test "LinearRGB.applyGammaVec" {
    const in = color.LinearRGB.init(0.25, 0.5, 0.75, 0.9);
    var in_vec: LinearRGB.T = undefined;
    for (0..vector_length) |i| {
        in_vec.r[i] = in.r;
        in_vec.g[i] = in.g;
        in_vec.b[i] = in.b;
        in_vec.a[i] = in.a;
    }

    const got = in.applyGamma();
    const got_vec = LinearRGB.applyGammaVec(in_vec);
    var expected_vec: LinearRGB.T = undefined;
    for (0..vector_length) |i| {
        expected_vec.r[i] = got.r;
        expected_vec.g[i] = got.g;
        expected_vec.b[i] = got.b;
        expected_vec.a[i] = got.a;
    }
    try testing.expectEqualDeep(expected_vec, got_vec);
}

test "LinearRGB.interpolateVec, LinearRGB.interpolateEncodeVec" {
    // Interpolation from red to green over the vector length.
    const red = color.LinearRGB.init(1, 0, 0, 0.9);
    const green = color.LinearRGB.init(0, 1, 0, 0.9);

    // Build params
    var red_vec: LinearRGB.T = undefined;
    var green_vec: LinearRGB.T = undefined;
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
    var expected: LinearRGB.T = undefined;
    var expected_encoded: pixel_vector.RGBA16 = undefined;
    for (0..vector_length) |i| {
        const expected_scalar = color.LinearRGB.interpolate(red, green, t_vec[i]);
        const expected_encoded_scalar = color.LinearRGB.interpolateEncode(red, green, t_vec[i]);
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

test "SRGB.fromColorVec" {
    // Simple test here designed to scale with vector_length, basically we do
    // Red in HSL, scaling on lightness from 0 - 0.5 in 1 / vector_length
    // intervals.
    var colors: [vector_length]color.Color = undefined;
    var expected: SRGB.T = undefined;
    for (0..vector_length) |i| {
        const j: f32 = @floatFromInt(i);
        const k: f32 = @floatFromInt(vector_length);
        colors[i] = color.HSL.init(0, 1, 0.5 * (1 / k * j), 1).asColor();
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

test "SRGB.encodeRGBAVec, SRGB.encodeRGBAVecRaw" {
    const in = color.SRGB.init(0.5296636, 0.7284379, 0.87481296, 0.9019608);
    var in_vec: SRGB.T = undefined;
    for (0..vector_length) |i| {
        in_vec.r[i] = in.r;
        in_vec.g[i] = in.g;
        in_vec.b[i] = in.b;
        in_vec.a[i] = in.a;
    }
    const got = color.SRGB.encodeRGBA(in);
    const got_vec = SRGB.encodeRGBAVec(in_vec);
    const got_raw = color.SRGB.encodeRGBARaw(in);
    const got_raw_vec = SRGB.encodeRGBAVecRaw(in_vec);
    var expected_vec: pixel_vector.RGBA16 = undefined;
    for (0..vector_length) |i| {
        expected_vec.r[i] = got.r;
        expected_vec.g[i] = got.g;
        expected_vec.b[i] = got.b;
        expected_vec.a[i] = got.a;
    }
    var expected_raw_vec: pixel_vector.RGBA16 = undefined;
    for (0..vector_length) |i| {
        expected_raw_vec.r[i] = got_raw.r;
        expected_raw_vec.g[i] = got_raw.g;
        expected_raw_vec.b[i] = got_raw.b;
        expected_raw_vec.a[i] = got_raw.a;
    }
    try testing.expectEqualDeep(expected_vec, got_vec);
    try testing.expectEqualDeep(expected_raw_vec, got_raw_vec);
}

test "SRGB.removeGammaVec" {
    const in = color.SRGB.init(0.25, 0.5, 0.75, 0.9);
    var in_vec: SRGB.T = undefined;
    for (0..vector_length) |i| {
        in_vec.r[i] = in.r;
        in_vec.g[i] = in.g;
        in_vec.b[i] = in.b;
        in_vec.a[i] = in.a;
    }
    const got = in.removeGamma();
    const got_vec = SRGB.removeGammaVec(in_vec);
    var expected_vec: SRGB.T = undefined;
    for (0..vector_length) |i| {
        expected_vec.r[i] = got.r;
        expected_vec.g[i] = got.g;
        expected_vec.b[i] = got.b;
        expected_vec.a[i] = got.a;
    }
    try testing.expectEqualDeep(expected_vec, got_vec);
}

test "SRGB.applyGammaVec" {
    const in = color.SRGB.init(0.25, 0.5, 0.75, 0.9);
    var in_vec: SRGB.T = undefined;
    for (0..vector_length) |i| {
        in_vec.r[i] = in.r;
        in_vec.g[i] = in.g;
        in_vec.b[i] = in.b;
        in_vec.a[i] = in.a;
    }
    const got = in.applyGamma();
    const got_vec = SRGB.applyGammaVec(in_vec);
    var expected_vec: SRGB.T = undefined;
    for (0..vector_length) |i| {
        expected_vec.r[i] = got.r;
        expected_vec.g[i] = got.g;
        expected_vec.b[i] = got.b;
        expected_vec.a[i] = got.a;
    }
    try testing.expectEqualDeep(expected_vec, got_vec);
}

test "SRGB.interpolateEncodeVec" {
    // Interpolation from red to green over the vector length.
    const red = color.SRGB.init(1, 0, 0, 0.9);
    const green = color.SRGB.init(0, 1, 0, 0.9);

    // Build params
    var red_vec: SRGB.T = undefined;
    var green_vec: SRGB.T = undefined;
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
    var expected: SRGB.T = undefined;
    var expected_encoded: pixel_vector.RGBA16 = undefined;
    for (0..vector_length) |i| {
        const expected_scalar = color.SRGB.interpolate(red, green, t_vec[i]);
        const expected_encoded_scalar = color.SRGB.interpolateEncode(red, green, t_vec[i]);
        expected.r[i] = expected_scalar.r;
        expected.g[i] = expected_scalar.g;
        expected.b[i] = expected_scalar.b;
        expected.a[i] = expected_scalar.a;
        expected_encoded.r[i] = expected_encoded_scalar.r;
        expected_encoded.g[i] = expected_encoded_scalar.g;
        expected_encoded.b[i] = expected_encoded_scalar.b;
        expected_encoded.a[i] = expected_encoded_scalar.a;
    }

    const got = SRGB.interpolateVec(red_vec, green_vec, t_vec);
    const got_encoded = SRGB.interpolateEncodeVec(red_vec, green_vec, t_vec);
    try testing.expectEqualDeep(expected, got);
    try testing.expectEqualDeep(expected_encoded, got_encoded);
}

test "HSL.fromColorVec" {
    // This the reverse of our fromColorVec tests for RGB, with a minor
    // modification (see below).
    var colors: [vector_length]color.Color = undefined;
    var expected: HSL.T = undefined;
    for (0..vector_length) |i| {
        // Bump j up so that it's 1-indexed versus 0-indexed, this ensures that
        // we don't actually init black (as we'll just get a zero-value HSL
        // back in that case).
        const j: f32 = @floatFromInt(i + 1);
        const k: f32 = @floatFromInt(vector_length);
        colors[i] = color.LinearRGB.init(1 * (1 / k * j), 0, 0, 1).asColor();
        expected.h[i] = 0;
        expected.s[i] = 1;
        expected.l[i] = 0.5 * (1 / k * j);
        expected.a[i] = 1;
    }
    const got = HSL.fromColorVec(colors);
    try testing.expectEqualDeep(expected, got);
}

test "HSL.toSRGBVec" {
    // This is just the SRGBLinear.fromColorVec test for HSL -> SRGB, just with
    // the color unwrapped.
    var src_vec: HSL.T = undefined;
    var expected: LinearRGB.T = undefined;
    for (0..vector_length) |i| {
        const j: f32 = @floatFromInt(i);
        const k: f32 = @floatFromInt(vector_length);
        const src = color.HSL.init(0, 1, 0.5 * (1 / k * j), 1);
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

test "HSL.demultiplyVec, divide by zero" {
    const in: HSL.T = .{
        .h = @splat(240),
        .s = @splat(0.5),
        .l = @splat(0.25),
        .a = @splat(0.0),
    };
    const got = HSL.demultiplyVec(in);
    const expected: HSL.T = .{
        .h = @splat(240),
        .s = @splat(0.0),
        .l = @splat(0.0),
        .a = @splat(0.0),
    };
    try testing.expectEqualDeep(expected, got);
}

test "HSL.interpolateEncodeVec" {
    // Interpolation from red to blue over the vector length.
    const red = color.HSL.init(0, 1, 0.5, 0.9);
    const blue = color.HSL.init(240, 1, 0.5, 0.9);

    // Build params
    var red_vec: HSL.T = undefined;
    var blue_vec: HSL.T = undefined;
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
    var expected_short: pixel_vector.RGBA16 = undefined;
    var expected_long: pixel_vector.RGBA16 = undefined;
    var expected_cw: pixel_vector.RGBA16 = undefined;
    var expected_ccw: pixel_vector.RGBA16 = undefined;
    for (0..vector_length) |i| {
        const expected_scalar_short = color.HSL.interpolateEncode(red, blue, t_vec[i], .shorter);
        const expected_scalar_long = color.HSL.interpolateEncode(red, blue, t_vec[i], .longer);
        const expected_scalar_cw = color.HSL.interpolateEncode(red, blue, t_vec[i], .increasing);
        const expected_scalar_ccw = color.HSL.interpolateEncode(red, blue, t_vec[i], .decreasing);
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

test "InterpolationMethod.interpolateVec, InterpolationMethod.interpolateEncodeVec" {
    const name = "InterpolationMethod.interpolateVec, InterpolationMethod.interpolateEncodeVec";
    const cases = [_]struct {
        name: []const u8,
        method: color.InterpolationMethod,
        a: color.Color,
        b: color.Color,
        t: f32,
    }{
        .{
            .name = ".linear_rgb, linear + linear",
            .method = .{ .linear_rgb = {} },
            .a = color.LinearRGB.init(1, 0, 0, 1).asColor(),
            .b = color.LinearRGB.init(0, 1, 0, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".linear_rgb, HSL + linear",
            .method = .{ .linear_rgb = {} },
            .a = color.HSL.init(0, 1, 0.5, 1).asColor(),
            .b = color.LinearRGB.init(0, 1, 0, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".linear_rgb, linear + HSL",
            .method = .{ .linear_rgb = {} },
            .a = color.LinearRGB.init(1, 0, 0, 1).asColor(),
            .b = color.HSL.init(120, 1, 0.5, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".linear_rgb, HSL + HSL",
            .method = .{ .linear_rgb = {} },
            .a = color.HSL.init(0, 1, 0.5, 1).asColor(),
            .b = color.HSL.init(120, 1, 0.5, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".linear_rgb, gamma + gamma",
            .method = .{ .linear_rgb = {} },
            .a = color.SRGB.init(math.pow(f32, 0.5, 1.0 / 2.2), 0, 0, 1).asColor(),
            .b = color.SRGB.init(0, math.pow(f32, 0.5, 1.0 / 2.2), 0, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".srgb, linear + linear",
            .method = .{ .srgb = {} },
            .a = color.LinearRGB.init(1, 0, 0, 1).asColor(),
            .b = color.LinearRGB.init(0, 1, 0, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".srgb, HSL + linear",
            .method = .{ .srgb = {} },
            .a = color.HSL.init(0, 1, 0.5, 1).asColor(),
            .b = color.LinearRGB.init(0, 1, 0, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".srgb, linear + HSL",
            .method = .{ .srgb = {} },
            .a = color.LinearRGB.init(1, 0, 0, 1).asColor(),
            .b = color.HSL.init(120, 1, 0.5, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".srgb, HSL + HSL",
            .method = .{ .srgb = {} },
            .a = color.HSL.init(0, 1, 0.5, 1).asColor(),
            .b = color.HSL.init(120, 1, 0.5, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".srgb, gamma + gamma",
            .method = .{ .srgb = {} },
            .a = color.SRGB.init(math.pow(f32, 0.5, 1.0 / 2.2), 0, 0, 1).asColor(),
            .b = color.SRGB.init(0, math.pow(f32, 0.5, 1.0 / 2.2), 0, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".hsl, shorter, linear + linear",
            .method = .{ .hsl = .shorter },
            .a = color.LinearRGB.init(1, 0, 0, 1).asColor(),
            .b = color.LinearRGB.init(0, 1, 0, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".hsl, shorter, HSL + linear",
            .method = .{ .hsl = .shorter },
            .a = color.HSL.init(0, 1, 0.5, 1).asColor(),
            .b = color.LinearRGB.init(0, 1, 0, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".hsl, shorter, linear + HSL",
            .method = .{ .hsl = .shorter },
            .a = color.LinearRGB.init(1, 0, 0, 1).asColor(),
            .b = color.HSL.init(120, 1, 0.5, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".hsl, shorter, HSL + HSL",
            .method = .{ .hsl = .shorter },
            .a = color.HSL.init(0, 1, 0.5, 1).asColor(),
            .b = color.HSL.init(120, 1, 0.5, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".hsl, shorter, gamma + gamma",
            .method = .{ .hsl = .shorter },
            .a = color.SRGB.init(math.pow(f32, 0.5, 1.0 / 2.2), 0, 0, 1).asColor(),
            .b = color.SRGB.init(0, math.pow(f32, 0.5, 1.0 / 2.2), 0, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".hsl, longer, linear + linear",
            .method = .{ .hsl = .longer },
            .a = color.LinearRGB.init(1, 0, 0, 1).asColor(),
            .b = color.LinearRGB.init(0, 1, 0, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".hsl, longer, HSL + linear",
            .method = .{ .hsl = .longer },
            .a = color.HSL.init(0, 1, 0.5, 1).asColor(),
            .b = color.LinearRGB.init(0, 1, 0, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".hsl, longer, linear + HSL",
            .method = .{ .hsl = .longer },
            .a = color.LinearRGB.init(1, 0, 0, 1).asColor(),
            .b = color.HSL.init(120, 1, 0.5, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".hsl, longer, HSL + HSL",
            .method = .{ .hsl = .longer },
            .a = color.HSL.init(0, 1, 0.5, 1).asColor(),
            .b = color.HSL.init(120, 1, 0.5, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".hsl, longer, gamma + gamma",
            .method = .{ .hsl = .longer },
            .a = color.SRGB.init(math.pow(f32, 0.5, 1.0 / 2.2), 0, 0, 1).asColor(),
            .b = color.SRGB.init(0, math.pow(f32, 0.5, 1.0 / 2.2), 0, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".hsl, increasing, linear + linear",
            .method = .{ .hsl = .increasing },
            .a = color.LinearRGB.init(1, 0, 0, 1).asColor(),
            .b = color.LinearRGB.init(0, 1, 0, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".hsl, increasing, HSL + linear",
            .method = .{ .hsl = .increasing },
            .a = color.HSL.init(0, 1, 0.5, 1).asColor(),
            .b = color.LinearRGB.init(0, 1, 0, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".hsl, increasing, linear + HSL",
            .method = .{ .hsl = .increasing },
            .a = color.LinearRGB.init(1, 0, 0, 1).asColor(),
            .b = color.HSL.init(120, 1, 0.5, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".hsl, increasing, HSL + HSL",
            .method = .{ .hsl = .increasing },
            .a = color.HSL.init(0, 1, 0.5, 1).asColor(),
            .b = color.HSL.init(120, 1, 0.5, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".hsl, increasing, gamma + gamma",
            .method = .{ .hsl = .increasing },
            .a = color.SRGB.init(math.pow(f32, 0.5, 1.0 / 2.2), 0, 0, 1).asColor(),
            .b = color.SRGB.init(0, math.pow(f32, 0.5, 1.0 / 2.2), 0, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".hsl, decreasing, linear + linear",
            .method = .{ .hsl = .decreasing },
            .a = color.LinearRGB.init(1, 0, 0, 1).asColor(),
            .b = color.LinearRGB.init(0, 1, 0, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".hsl, decreasing, HSL + linear",
            .method = .{ .hsl = .decreasing },
            .a = color.HSL.init(0, 1, 0.5, 1).asColor(),
            .b = color.LinearRGB.init(0, 1, 0, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".hsl, decreasing, linear + HSL",
            .method = .{ .hsl = .decreasing },
            .a = color.LinearRGB.init(1, 0, 0, 1).asColor(),
            .b = color.HSL.init(120, 1, 0.5, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".hsl, decreasing, HSL + HSL",
            .method = .{ .hsl = .decreasing },
            .a = color.HSL.init(0, 1, 0.5, 1).asColor(),
            .b = color.HSL.init(120, 1, 0.5, 1).asColor(),
            .t = 0.5,
        },
        .{
            .name = ".hsl, decreasing, gamma + gamma",
            .method = .{ .hsl = .decreasing },
            .a = color.SRGB.init(math.pow(f32, 0.5, 1.0 / 2.2), 0, 0, 1).asColor(),
            .b = color.SRGB.init(0, math.pow(f32, 0.5, 1.0 / 2.2), 0, 1).asColor(),
            .t = 0.5,
        },
    };
    const TestFn = struct {
        fn f(tc: anytype) TestingError!void {
            var a_vec: [vector_length]color.Color = undefined;
            var b_vec: [vector_length]color.Color = undefined;
            var t_vec: [vector_length]f32 = undefined;
            var expected: LinearRGB.T = undefined;
            var expected_encoded: pixel_vector.RGBA16 = undefined;
            for (0..vector_length) |i| {
                a_vec[i] = tc.a;
                b_vec[i] = tc.b;
                const j: f32 = @floatFromInt(i);
                const k: f32 = @floatFromInt(vector_length);
                t_vec[i] = 1 / k * j;
                const expected_scalar = color.LinearRGB.fromColor(tc.method.interpolate(tc.a, tc.b, t_vec[i]));
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
            const got = interpolateVec(tc.method, a_vec, b_vec, t_vec);
            const got_encoded = interpolateEncodeVec(tc.method, a_vec, b_vec, t_vec);
            try testing.expectEqualDeep(expected, got);
            try testing.expectEqualDeep(expected_encoded, got_encoded);
        }
    };
    try runCases(name, cases, TestFn.f);
}

test "Dither.getRGBAVec" {
    const name = "Dither.getRGBAVec";
    const cases = [_]struct {
        name: []const u8,
        type: Dither.Type,
        source: union(enum) {
            pixel: pixel.Pixel,
            color: color.Color.InitArgs,
            gradient: void,
        },
        scale: u4,
        x: i32,
        y: i32,
    }{
        .{
            .name = "no dither",
            .type = .none,
            .source = .{ .pixel = .{ .rgba = .{ .r = 255, .g = 255, .b = 255, .a = 255 } } },
            .scale = 1, // Driving the scale down here should validate the short-circuit
            .x = 0,
            .y = 0,
        },
        .{
            .name = "pixel",
            .type = .bayer,
            .source = .{ .pixel = .{ .rgba = .{ .r = 255, .g = 255, .b = 255, .a = 255 } } },
            .scale = 8,
            .x = 0,
            .y = 0,
        },
        .{
            .name = "color",
            .type = .bayer,
            .source = .{ .color = .{ .rgb = .{ 1, 1, 1 } } },
            .scale = 8,
            .x = 0,
            .y = 0,
        },
        .{
            .name = "gradient",
            .type = .bayer,
            .source = .gradient,
            .scale = 8,
            .x = 49,
            .y = 20,
        },
        .{
            .name = "blue noise",
            .type = .blue_noise,
            .source = .gradient,
            .scale = 8,
            .x = 0,
            .y = 49,
        },
    };
    const TestFn = struct {
        fn f(tc: anytype) TestingError!void {
            var stop_buffer: [2]gradient.Stop = undefined;
            var g: gradient.Gradient = gradient.Gradient.init(.{
                .type = .{
                    .linear = .{ .x0 = 0, .y0 = 0, .x1 = 99, .y1 = 99 },
                },
                .stops = &stop_buffer,
            });
            const d: Dither = .{
                .type = tc.type,
                .source = switch (tc.source) {
                    .pixel => |s| .{ .pixel = s },
                    .color => |s| .{ .color = s },
                    .gradient => .{ .gradient = &g },
                },
                .scale = tc.scale,
            };
            var expected: pixel_vector.RGBA16 = undefined;
            for (0..vector_length) |i| {
                const expected_scalar = pixel.RGBA.fromPixel(d.getPixel(tc.x + @as(i32, @intCast(i)), tc.y));
                expected.r[i] = expected_scalar.r;
                expected.g[i] = expected_scalar.g;
                expected.b[i] = expected_scalar.b;
                expected.a[i] = expected_scalar.a;
            }
            try testing.expectEqualDeep(expected, fromDitherVecEncode(&d, tc.x, tc.y, false, 0));
        }
    };
    try runCases(name, cases, TestFn.f);
}
