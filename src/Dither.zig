// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2025 Chris Marchesi

//! Dither patterns are special pattern types that wrap other patterns to apply
//! noise from a pre-built matrix, which can help to correct color banding or
//! approximate colors at a lower bit depth.
//!
//! This is a lower-level pattern and should not be used directly. Rather, use
//! `Context.setDither` or supply the field directly as a source stage in
//! the appropriate functionality in the `compositor` package.
const Dither = @This();

const debug = @import("std").debug;
const math = @import("std").math;
const mem = @import("std").mem;
const testing = @import("std").testing;

const colorpkg = @import("color.zig");
const gradientpkg = @import("gradient.zig");
const pixelpkg = @import("pixel.zig");
const Color = colorpkg.Color;
const Gradient = gradientpkg.Gradient;
const Pixel = pixelpkg.Pixel;

const dither_blue_noise_64x64 = @import("internal/blue_noise.zig").dither_blue_noise_64x64;
const vector_length = @import("compositor.zig").vector_length;

const gather = @import("internal/util.zig").gather;
const splat = @import("internal/util.zig").splat;
const vectorize = @import("internal/util.zig").vectorize;
const runCases = @import("internal/util.zig").runCases;
const TestingError = @import("internal/util.zig").TestingError;

/// The types of dithering supported.
pub const Type = enum {
    /// No dithering.
    none,

    /// Ordered dithering using a Bayer 8x8 matrix.
    bayer,

    /// Ordered dithering using a pre-generated 64x64 blue noise matrix (aka
    /// void-and-cluster).
    blue_noise,
};

/// The types of dithering sources supported.
pub const Source = union(enum) {
    /// A pixel source. This is converted to linear RGB before applying the
    /// dither.
    pixel: Pixel,

    /// A color source, converted to linear RGB before applying the dither.
    color: Color.InitArgs,

    /// A gradient. After interpolation, the result is converted to linear RGB
    /// and the dither is applied.
    gradient: *Gradient,
};

/// The dithering type in use.
type: Type,

/// The source for the dither.
source: Source,

/// The scale factor used when applying the dither. This should be the target
/// bit depth, e.g. 8 when doing standard RGBA. This scales interpolation at
/// 1 / (2^n - 1) when applying the dither.
///
/// Note this is limited to u4 as dithering beyond 8 bpc will get you
/// increasingly diminishing returns (generally, it's not useful to dither past
/// 10bpc).
///
/// `Context.setDither` will set this to the bpc of the destination surface.
scale: u4,

/// Fetches and dithers the pixel according to the (x, y) co-ordinates.
pub fn getPixel(self: *const Dither, x: i32, y: i32) Pixel {
    const rgba: colorpkg.LinearRGB = switch (self.source) {
        .pixel => |src| colorpkg.LinearRGB.decodeRGBA(pixelpkg.RGBA.fromPixel(src)),
        .color => |src| colorpkg.LinearRGB.fromColor(Color.init(src)),
        .gradient => |src| g: {
            const search_result = src.searchInStops(src.getOffset(x, y));
            break :g colorpkg.LinearRGB.fromColor(src.getInterpolationMethod().interpolate(
                search_result.c0,
                search_result.c1,
                search_result.offset,
            ));
        },
    };
    const m: f32 = switch (self.type) {
        .none => return rgba.encodeRGBA().asPixel(),
        .bayer => mBayer8x8(x, y),
        .blue_noise => mBlueNoise64x64(x, y),
    };
    const scale: f32 = 1.0 / @as(f32, @floatFromInt((@as(usize, 1) << self.scale) - 1));
    return colorpkg.LinearRGB.encodeRGBA(.{
        .r = apply_dither(rgba.r, m, scale),
        .g = apply_dither(rgba.g, m, scale),
        .b = apply_dither(rgba.b, m, scale),
        .a = apply_dither(rgba.a, m, scale),
    }).asPixel();
}

/// Vectorized version of `getPixel`. Designed for internal use by the
/// compositor; YMMV when using externally.
pub fn getRGBAVec(
    self: *const Dither,
    x: i32,
    y: i32,
    comptime limit: bool,
    limit_len: usize,
) vectorize(pixelpkg.RGBA) {
    return colorpkg.LinearRGB.encodeRGBAVec(self.getColorVec(
        x,
        y,
        limit,
        limit_len,
    ));
}

const zero_float_vec = @import("internal/util.zig").zero_float_vec;
const zero_color_vec = @import("internal/util.zig").zero_color_vec;

/// Vectorized color dithering. Designed for internal use by the compositor;
/// YMMV when using externally.
pub fn getColorVec(
    self: *const Dither,
    x: i32,
    y: i32,
    comptime limit: bool,
    limit_len: usize,
) colorpkg.LinearRGB.Vector {
    if (limit) debug.assert(limit_len < vector_length);
    const rgba: vectorize(colorpkg.LinearRGB) = switch (self.source) {
        .pixel => |src| c: {
            const c = colorpkg.LinearRGB.decodeRGBA(pixelpkg.RGBA.fromPixel(src));
            break :c .{
                .r = @splat(c.r),
                .g = @splat(c.g),
                .b = @splat(c.b),
                .a = @splat(c.a),
            };
        },
        .color => |src| c: {
            const c = colorpkg.LinearRGB.fromColor(Color.init(src));
            break :c .{
                .r = @splat(c.r),
                .g = @splat(c.g),
                .b = @splat(c.b),
                .a = @splat(c.a),
            };
        },
        .gradient => |src| c: {
            var c0_vec: [vector_length]colorpkg.Color = zero_color_vec;
            var c1_vec: [vector_length]colorpkg.Color = zero_color_vec;
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
            break :c src.getInterpolationMethod().interpolateVec(
                c0_vec,
                c1_vec,
                offsets_vec,
            );
        },
    };
    const m: @Vector(vector_length, f32) = switch (self.type) {
        .none => return rgba,
        .bayer => mBayer8x8Vec(x, y),
        .blue_noise => mBlueNoise64x64Vec(x, y),
    };
    const scale = splat(f32, 1.0 / @as(
        f32,
        @floatFromInt((@as(usize, 1) << self.scale) - 1),
    ));
    return .{
        .r = apply_dither(rgba.r, m, scale),
        .g = apply_dither(rgba.g, m, scale),
        .b = apply_dither(rgba.b, m, scale),
        .a = apply_dither(rgba.a, m, scale),
    };
}

fn apply_dither(value: anytype, m: anytype, scale: anytype) @TypeOf(value) {
    const lower = if (@typeInfo(@TypeOf(value)) == .Vector) splat(f32, 0.0) else 0.0;
    const upper = if (@typeInfo(@TypeOf(value)) == .Vector) splat(f32, 1.0) else 1.0;
    return math.clamp(value + m * scale, lower, upper);
}

// Virtual matrix functions for computing pre-calculated threshold values for
// the Bayer 8x8 matrix, as described in
// https://en.wikipedia.org/w/index.php?title=Ordered_dithering&oldid=1274797463,
// archive link:
// https://web.archive.org/web/20250302193807/https://en.wikipedia.org/w/index.php?title=Ordered_dithering&oldid=1274797463
//
// The breakdown: this is the Bayer 8x8 matrix, initialized to the cited
//   M(i, j) = bit_reverse(bit_interleave(bitwise_xor(i, j), i))
//
// And then normalized with the pre-calculation applied, as shown in:
//   Mpre(i,j) = Mint(i,j) / n^2 – 0.5 * maxValue
//
// Values are normally looked up in a ordered dithering matrix via (mod(x),
// mod(y).
//
// The bit shifting technique (explained below) makes it easy to roll the
// modulus that needs to happen on each lookup (which would normally happen
// every time you were looking up into a pre-generated matrix on the (x, y)
// co-ordinate) into the interleave + reverse of the results that are used to
// generate the matrix. We then apply the division and the normalized offset; a
// 1/128 epsilon is applied to the offset to ensure that we don't overflow
// values on the high or low ends.
//
// This threshold value is further multiplied in the dithering process by a
// factor of 1 / (2^scale - 1), where scale should be the bpc of the color
// being dithered (in our case, manually controlled by the "scale" value in the
// struct).
//
// Finally, as promised, the primer on modulus division via bit shifting: when
// doing n mod d, when the denominator (d) is a power of two, you can take the
// bit size of 0 to d-1, (so 3 bits for d = 8), and mask the max (i.e., 7, or
// 0b111) against your numerator (n). The method below exploits this and then
// uses the result directly, interleaving and reversing these results in one
// swoop. Also, note that the order of the xor and the mod are communicative
// since we've just reduced the problem to a bitwise one that isn't shuffling
// any bits around.

fn mBayer8x8(x: i32, y: i32) f32 {
    const _y = y ^ x;
    const m: u32 = @intCast((_y & 1) << 5 | (x & 1) << 4 |
        (_y & 2) << 2 | (x & 2) << 1 |
        (_y & 4) >> 1 | (x & 4) >> 2);
    return @as(f32, @floatFromInt(m)) * (2.0 / 128.0) - (63.0 / 128.0);
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

fn mBlueNoise64x64(x: i32, y: i32) f32 {
    // The index for looking up into the blue noise matrix (any matrix for
    // ordered dithering, actually) is (mod(x), mod(y)). Our blue noise matrix
    // is flat (not multidimensional), so we just OR these values to get our
    // index (avoids the mul + add).
    const idx: usize = @intCast(@mod(x, 64) << 6 | @mod(y, 64));
    const m = dither_blue_noise_64x64[idx];
    // As with the bayer 8x8, we apply the normalized offset w/epsilon.
    return @as(f32, @floatFromInt(m)) * (2.0 / 8192.0) - (4095.0 / 8192.0);
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

// Note that most of our tests will end up only doing rudimentary tests here
// and serve mainly as build and maybe edge case testing. Comprehensive testing
// should be done as acceptance (spec/) tests.

test "Dither.getPixel" {
    const name = "Dither.getPixel";
    const cases = [_]struct {
        name: []const u8,
        expected: Pixel,
        type: Type,
        source: union(enum) {
            pixel: Pixel,
            color: Color.InitArgs,
            gradient: void,
        },
        scale: u4,
        x: i32,
        y: i32,
    }{
        .{
            .name = "no dither",
            .expected = .{ .rgba = .{ .r = 255, .g = 255, .b = 255, .a = 255 } },
            .type = .none,
            .source = .{ .pixel = .{ .rgba = .{ .r = 255, .g = 255, .b = 255, .a = 255 } } },
            .scale = 1, // Driving the scale down here should validate the short-circuit
            .x = 0,
            .y = 0,
        },
        .{
            .name = "pixel",
            .expected = .{ .rgba = .{ .r = 255, .g = 255, .b = 255, .a = 255 } },
            .type = .bayer,
            .source = .{ .pixel = .{ .rgba = .{ .r = 255, .g = 255, .b = 255, .a = 255 } } },
            .scale = 8,
            .x = 0,
            .y = 0,
        },
        .{
            .name = "color",
            .expected = .{ .rgba = .{ .r = 255, .g = 255, .b = 255, .a = 255 } },
            .type = .bayer,
            .source = .{ .color = .{ .rgb = .{ 1, 1, 1 } } },
            .scale = 8,
            .x = 0,
            .y = 0,
        },
        .{
            .name = "gradient",
            .expected = .{ .rgba = .{ .r = 127, .g = 127, .b = 127, .a = 255 } },
            .type = .bayer,
            .source = .gradient,
            .scale = 8,
            .x = 49,
            .y = 49,
        },
        .{
            .name = "scale",
            // TODO: Note the alpha channel - I need to validate the dither at
            // lower scale factors. I think this is okay (just testing with
            // Cairo on the 16-bit surfaces shows noise at the high ends of
            // gradients, so this is not entirely unexpected), but I'd like to
            // check at super low bpp and Cairo unfortunately does not support
            // surfaces below 16-bit, just alpha surfaces and I think their
            // behavior for exporting there is different (so we'd need to test
            // on proper grayscale).
            .expected = .{ .rgba = .{ .r = 29, .g = 29, .b = 29, .a = 213 } },
            .type = .bayer,
            .source = .{ .color = .{ .rgb = .{ 0.3, 0.3, 0.3 } } },
            .scale = 2,
            .x = 0,
            .y = 0,
        },
        .{
            .name = "blue noise",
            .expected = .{ .rgba = .{ .r = 127, .g = 127, .b = 127, .a = 255 } },
            .type = .blue_noise,
            .source = .gradient,
            .scale = 8,
            .x = 49,
            .y = 49,
        },
    };
    const TestFn = struct {
        fn f(tc: anytype) TestingError!void {
            var stop_buffer: [2]gradientpkg.Stop = undefined;
            var g: Gradient = Gradient.init(.{
                .type = .{
                    .linear = .{ .x0 = 0, .y0 = 0, .x1 = 99, .y1 = 99 },
                },
                .stops = &stop_buffer,
            });
            g.addStopAssumeCapacity(0, .{ .rgb = .{ 0, 0, 0 } });
            g.addStopAssumeCapacity(1, .{ .rgb = .{ 1, 1, 1 } });
            const d: Dither = .{
                .type = tc.type,
                .source = switch (tc.source) {
                    .pixel => |s| .{ .pixel = s },
                    .color => |s| .{ .color = s },
                    .gradient => .{ .gradient = &g },
                },
                .scale = tc.scale,
            };
            try testing.expectEqualDeep(tc.expected, d.getPixel(tc.x, tc.y));
        }
    };
    try runCases(name, cases, TestFn.f);
}

test "Dither.getRGBAVec" {
    const name = "Dither.getRGBAVec";
    const cases = [_]struct {
        name: []const u8,
        type: Type,
        source: union(enum) {
            pixel: Pixel,
            color: Color.InitArgs,
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
            var stop_buffer: [2]gradientpkg.Stop = undefined;
            var g: Gradient = Gradient.init(.{
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
            var expected: vectorize(pixelpkg.RGBA) = undefined;
            for (0..vector_length) |i| {
                const expected_scalar = pixelpkg.RGBA.fromPixel(d.getPixel(tc.x + @as(i32, @intCast(i)), tc.y));
                expected.r[i] = expected_scalar.r;
                expected.g[i] = expected_scalar.g;
                expected.b[i] = expected_scalar.b;
                expected.a[i] = expected_scalar.a;
            }
            try testing.expectEqualDeep(expected, d.getRGBAVec(tc.x, tc.y, false, 0));
        }
    };
    try runCases(name, cases, TestFn.f);
}
