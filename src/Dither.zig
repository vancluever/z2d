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

const math = @import("std").math;
const testing = @import("std").testing;

const colorpkg = @import("color.zig");
const gradientpkg = @import("gradient.zig");
const pixelpkg = @import("pixel.zig");
const Color = colorpkg.Color;
const Gradient = gradientpkg.Gradient;
const Pixel = pixelpkg.Pixel;

const dither_blue_noise_64x64 = @import("internal/blue_noise.zig").dither_blue_noise_64x64;

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

fn apply_dither(value: f32, m: f32, scale: f32) f32 {
    return math.clamp(value + m * scale, 0.0, 1.0);
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
