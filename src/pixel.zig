// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024-2026 Chris Marchesi

//! Pixel types represented by the library.

const std = @import("std");

const compositor = @import("compositor.zig");

const colorpkg = @import("color.zig");
const Color = colorpkg.Color;

const runCases = @import("internal/util.zig").runCases;
const TestingError = @import("internal/util.zig").TestingError;

/// Format descriptors for the pixel formats supported by the library:
///
/// ### Packed pixel formats
///
/// The following formats are contained within packed structs. In these
/// formats, the layout of the pixel data in memory follows the endianness of
/// the system.
///
/// All of these formats are described in the perspective of their packed
/// fields within their backing integers. The least significant field is on the
/// right. Example: with `.argb`, the layout `A:R:G:B` means that the blue
/// channel (`B`) occupies the least significant bits in the packing integer,
/// and appears first in the struct field order.
///
/// Additionally, note that when trying to visualize how these values are laid
/// out in memory, it's important to remember that it's the *backing integer*
/// that matters, not individual values. As an example, in the truecolor
/// formats, where the backing integer is a u32 and each channel is 8 bits,
/// each byte will line up neatly giving the correct color, and you can view
/// the layout from the perspective of the 1st field in the packed struct to
/// the last. However, in 16-bit packed formats, where each value is less than
/// 8 bits, this no longer holds, and the layout must be looked at in the
/// perspective of the integer as a whole, not individual bytes.
///
/// #### True color formats
///
/// All formats are 8bpc u32. `x` denotes an unused alpha channel.
///
/// * `.argb`: layout `A:R:G:B` (`8:8:8:8` bitfield layout).
/// * `.xrgb`: layout `x:R:G:B` (`8:8:8:8` bitfield layout).
/// * `.rgba`: layout `A:B:G:R` (`8:8:8:8` bitfield layout).
/// * `.rgb`:  layout `x:B:G:R` (`8:8:8:8` bitfield layout).
///
/// #### High color formats
///
/// The following are 16-bit formats.
///
/// * `rgb565`: layout `B:G:R` (`5:6:5` bitfield layout).
///
/// ### Array-layout formats
///
/// The following formats have a guaranteed memory layout regardless of
/// endianness, and are backed by value arrays rather than integers. In all
/// formats, individual fields must be accessed through accessors or their
/// field enum values as defined for each type.
///
/// Currently all formats are 8 bits per channel.
///
/// #### True color formats
///
/// All formats are exactly 24 bits (represented as [3]u8).
///
/// * `.rgb24`: layout `R:G:B` (indices `0:1:2`).
/// * `.bgr24`: layout `B:G:R` (indices `0:1:2`).
///
/// ### Alpha-only formats
///
/// All alpha channels below 8 bits will be packed into memory when used as the
/// pixel type of a `Surface`. Bit packing is little endian regardless of
/// system architecture. For more information, see `PackedImageSurface`.
///
/// * `.alpha8` is an 8-bit alpha channel.
/// * `.alpha4` is an 4-bit alpha channel.
/// * `.alpha2` is an 2-bit alpha channel.
/// * `.alpha1` is a 1-bit alpha channel.
pub const Format = enum {
    argb,
    xrgb,
    rgb,
    rgba,
    rgb24,
    bgr24,
    rgb565,
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
    /// Represented as a packed `[]u8` buffer, see `Alpha` for help with
    /// getting pixels out.
    fn Packed8(px_T: type) type {
        return struct {
            pub const T = px_T;
            buf: []u8,
            px_offset: usize,
            px_len: usize,
        };
    }

    argb: []ARGB,
    xrgb: []XRGB,
    rgb: []RGB,
    rgba: []RGBA,
    rgb24: []RGB24,
    bgr24: []BGR24,
    rgb565: []RGB565,
    alpha8: []Alpha8,
    alpha4: Packed8(Alpha4),
    alpha2: Packed8(Alpha2),
    alpha1: Packed8(Alpha1),

    /// Returns the pixel length of the stride.
    pub fn pxLen(self: Stride) usize {
        return switch (self) {
            inline .argb, .xrgb, .rgb, .rgba, .rgb24, .bgr24, .rgb565, .alpha8 => |s| s.len,
            inline .alpha4, .alpha2, .alpha1 => |s| s.px_len,
        };
    }
};

/// Represents an interface as a union of the pixel formats.
pub const Pixel = union(Format) {
    argb: ARGB,
    xrgb: XRGB,
    rgb: RGB,
    rgba: RGBA,
    rgb24: RGB24,
    bgr24: BGR24,
    rgb565: RGB565,
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

    /// Initializes a wrapped RGBA pixel from the supplied color verb.
    pub fn fromColor(color: Color.InitArgs) Pixel {
        return colorpkg.LinearRGB.fromColor(Color.init(color)).encodeRGBA().asPixel();
    }

    /// Convenience method that returns true if the pixel is full-opacity.
    ///
    /// Note that:
    ///
    ///  * Any pixel type lacking an alpha channel (e.g., `RGB`) is always
    ///    considered opaque.
    ///  * Alpha types (e.g., `Alpha8` or the sub-8-bit versions) follow the
    ///    same opacity rules as RGBA types (full opacity is max alpha channel
    ///    value). Keep this in mind when using alpha-only pixel types to
    ///    represent grayscale.
    pub fn isOpaque(self: Pixel) bool {
        return switch (self) {
            inline .xrgb, .rgb, .rgb24, .bgr24, .rgb565 => true,
            inline .argb, .rgba, .alpha8 => |px| px.a == 255,
            .alpha4 => |px| px.a == 15,
            .alpha2 => |px| px.a == 3,
            .alpha1 => |px| px.a == 1,
        };
    }
};

/// Describes a 32-bit little-endian xRGB format (can also be thought of as
/// ARGB with a disabled alpha channel.
pub const XRGB = packed struct(u32) {
    b: u8,
    g: u8,
    r: u8,
    _padding: u8 = 0,

    /// The format descriptor for this pixel format.
    pub const format: Format = .xrgb;

    /// Returns a pixel from a clamped 0-1 value.
    pub fn fromClamped(r: f32, g: f32, b: f32) XRGB {
        return RGBA_T(@This()).fromClamped(r, g, b, 1);
    }

    /// Returns the pixel translated to XRGB.
    pub fn fromPixel(p: Pixel) XRGB {
        return RGBA_T(@This()).fromPixel(p);
    }

    /// Returns an average of the pixels in the supplied slice. The average of
    /// a zero-length slice is pure black.
    ///
    /// This function is limited to 256 entries; any higher than this is
    /// safety-checked undefined behavior.
    pub fn average(ps: []const XRGB) XRGB {
        return RGBA_T(@This()).average(ps);
    }

    /// Returns this pixel as an interface.
    pub fn asPixel(self: XRGB) Pixel {
        return RGBA_T(@This()).asPixel(self);
    }

    /// Returns `true` if the supplied pixels are equal.
    pub fn equal(self: XRGB, other: Pixel) bool {
        return RGBA_T(@This()).equal(self, other);
    }
};

/// Describes a 32-bit RGBx format (or xBGR when described as little endian);
/// can also be thought of as RGBA with disabled alpha channel.
pub const RGB = packed struct(u32) {
    r: u8,
    g: u8,
    b: u8,
    _padding: u8 = 0,

    /// The format descriptor for this pixel format.
    pub const format: Format = .rgb;

    /// Returns a pixel from a clamped 0-1 value.
    pub fn fromClamped(r: f32, g: f32, b: f32) RGB {
        return RGBA_T(@This()).fromClamped(r, g, b, 1);
    }

    /// Returns the pixel translated to RGB.
    pub fn fromPixel(p: Pixel) RGB {
        return RGBA_T(@This()).fromPixel(p);
    }

    /// Returns an average of the pixels in the supplied slice. The average of
    /// a zero-length slice is pure black.
    ///
    /// This function is limited to 256 entries; any higher than this is
    /// safety-checked undefined behavior.
    pub fn average(ps: []const RGB) RGB {
        return RGBA_T(@This()).average(ps);
    }

    /// Returns this pixel as an interface.
    pub fn asPixel(self: RGB) Pixel {
        return RGBA_T(@This()).asPixel(self);
    }

    /// Returns `true` if the supplied pixels are equal.
    pub fn equal(self: RGB, other: Pixel) bool {
        return RGBA_T(@This()).equal(self, other);
    }
};

/// Describes a 32-bit little-endian ARGB format.
///
/// Note that all compositing operations in z2d expect a pre-multiplied alpha.
/// You can convert between pre-multiplied and straight alpha using `multiply`
/// and `demultiply`. Additionally, `fromClamped` takes straight alpha.
pub const ARGB = packed struct(u32) {
    b: u8,
    g: u8,
    r: u8,
    a: u8,

    /// The format descriptor for this pixel format.
    pub const format: Format = .argb;

    /// Returns a pixel from a clamped 0-1 value. The helper expects the values
    /// as straight alpha and will pre-multiply the values for you.
    pub fn fromClamped(r: f32, g: f32, b: f32, a: f32) ARGB {
        return RGBA_T(@This()).fromClamped(r, g, b, a);
    }

    /// Returns the pixel translated to ARGB.
    pub fn fromPixel(p: Pixel) ARGB {
        return RGBA_T(@This()).fromPixel(p);
    }

    /// Returns an average of the pixels in the supplied slice. The average of
    /// a zero-length slice is transparent black.
    ///
    /// This function is limited to 256 entries; any higher than this is
    /// safety-checked undefined behavior.
    pub fn average(ps: []const ARGB) ARGB {
        return RGBA_T(@This()).average(ps);
    }

    /// Returns this pixel as an interface.
    pub fn asPixel(self: ARGB) Pixel {
        return RGBA_T(@This()).asPixel(self);
    }

    /// Returns `true` if the supplied pixels are equal.
    pub fn equal(self: ARGB, other: Pixel) bool {
        return RGBA_T(@This()).equal(self, other);
    }

    /// Returns a new ARGB value, with the color values multiplied by the alpha
    /// (as alpha / 255).
    pub fn multiply(self: ARGB) ARGB {
        return RGBA_T(@This()).multiply(self);
    }

    /// Returns a new ARGB value, with the color values de-multiplied by the
    /// alpha.
    ///
    /// While this is designed to reverse pre-multiplied alpha values (the
    /// product of multiply), the reversed value may not be 100% accurate to
    /// the original due to remainder loss.
    ///
    /// As a special case, a zero alpha de-multiplies into transparent black.
    pub fn demultiply(self: ARGB) ARGB {
        return RGBA_T(@This()).demultiply(self);
    }

    /// Returns `true` if the value can be de-multipled. This ultimately
    /// validates that the value is safe for compositor operations.
    pub fn canDemultiply(self: ARGB) bool {
        return RGBA_T(@This()).canDemultiply(self);
    }
};

/// Describes a 32-bit RGBA format (or ABGR when described a little-endian).
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
    pub fn fromClamped(r: f32, g: f32, b: f32, a: f32) RGBA {
        return RGBA_T(@This()).fromClamped(r, g, b, a);
    }

    /// Returns the pixel translated to RGBA.
    pub fn fromPixel(p: Pixel) RGBA {
        return RGBA_T(@This()).fromPixel(p);
    }

    /// Returns an average of the pixels in the supplied slice. The average of
    /// a zero-length slice is transparent black.
    ///
    /// This function is limited to 256 entries; any higher than this is
    /// safety-checked undefined behavior.
    pub fn average(ps: []const RGBA) RGBA {
        return RGBA_T(@This()).average(ps);
    }

    /// Returns this pixel as an interface.
    pub fn asPixel(self: RGBA) Pixel {
        return RGBA_T(@This()).asPixel(self);
    }

    /// Returns `true` if the supplied pixels are equal.
    pub fn equal(self: RGBA, other: Pixel) bool {
        return RGBA_T(@This()).equal(self, other);
    }

    /// Returns a new RGBA value, with the color values multiplied by the alpha
    /// (as alpha / 255).
    pub fn multiply(self: RGBA) RGBA {
        return RGBA_T(@This()).multiply(self);
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
        return RGBA_T(@This()).demultiply(self);
    }

    /// Returns `true` if the value can be de-multipled. This ultimately
    /// validates that the value is safe for compositor operations.
    pub fn canDemultiply(self: RGBA) bool {
        return RGBA_T(@This()).canDemultiply(self);
    }
};

/// Utility namespace for common RGB(A) functionality. `T` must be one of the
/// RGB(A) formats.
///
/// Refer to the upstream types for documentation on each individual function.
fn RGBA_T(T: type) type {
    switch (T) {
        XRGB, RGB, ARGB, RGBA => {},
        else => @compileError("invalid type for RGBA_T utility functions"),
    }

    const is_rgba = T.format == .rgba or T.format == .argb;

    return struct {
        fn fromClamped(r: f32, g: f32, b: f32, a: f32) T {
            const rc = std.math.clamp(r, 0, 1);
            const gc = std.math.clamp(g, 0, 1);
            const bc = std.math.clamp(b, 0, 1);
            const ac = std.math.clamp(a, 0, 1);
            if (is_rgba) {
                const result: T = .{
                    .r = @intFromFloat(@round(255.0 * rc)),
                    .g = @intFromFloat(@round(255.0 * gc)),
                    .b = @intFromFloat(@round(255.0 * bc)),
                    .a = @intFromFloat(@round(255.0 * ac)),
                };
                return result.multiply();
            }

            return .{
                .r = @intFromFloat(@round(255.0 * rc)),
                .g = @intFromFloat(@round(255.0 * gc)),
                .b = @intFromFloat(@round(255.0 * bc)),
            };
        }

        fn fromPixel(p: Pixel) T {
            if (p == T.format) return @field(p, @tagName(T.format));

            const rgb: RGB = switch (p) {
                inline .xrgb, .rgb, .argb, .rgba => |q| .{
                    .r = q.r,
                    .g = q.g,
                    .b = q.b,
                },
                inline .rgb24, .bgr24 => |q| .{
                    .r = q.r(),
                    .g = q.g(),
                    .b = q.b(),
                },
                .rgb565 => |q| RGB565.toRGB(q),
                .alpha8, .alpha4, .alpha2, .alpha1 => .{
                    .r = 0,
                    .g = 0,
                    .b = 0,
                },
            };

            const alpha: Alpha8 = if (is_rgba) Alpha8.fromPixel(p) else undefined;

            return if (is_rgba)
                .{ .r = rgb.r, .g = rgb.g, .b = rgb.b, .a = alpha.a }
            else
                .{ .r = rgb.r, .g = rgb.g, .b = rgb.b };
        }

        fn average(ps: []const T) T {
            std.debug.assert(ps.len <= 256);
            if (ps.len == 0) return if (is_rgba)
                .{ .r = 0, .g = 0, .b = 0, .a = 0 }
            else
                .{ .r = 0, .g = 0, .b = 0 };

            var r: u16 = 0;
            var g: u16 = 0;
            var b: u16 = 0;
            var a: u16 = 0;

            for (ps) |p| {
                r += p.r;
                g += p.g;
                b += p.b;
                if (is_rgba) a += p.a;
            }

            return if (is_rgba) .{
                .r = @intCast(r / ps.len),
                .g = @intCast(g / ps.len),
                .b = @intCast(b / ps.len),
                .a = @intCast(a / ps.len),
            } else .{
                .r = @intCast(r / ps.len),
                .g = @intCast(g / ps.len),
                .b = @intCast(b / ps.len),
            };
        }

        fn asPixel(self: T) Pixel {
            return @unionInit(Pixel, @tagName(T.format), self);
        }

        fn equal(self: T, other: Pixel) bool {
            if (other == T.format) {
                const o = @field(other, @tagName(T.format));
                if (is_rgba) {
                    return self.r == o.r and self.g == o.g and self.b == o.b and self.a == o.a;
                }

                return self.r == o.r and self.g == o.g and self.b == o.b;
            }

            return false;
        }

        fn multiply(self: T) T {
            std.debug.assert(is_rgba);
            return .{
                .r = @intCast(@as(u16, self.r) * self.a / 255),
                .g = @intCast(@as(u16, self.g) * self.a / 255),
                .b = @intCast(@as(u16, self.b) * self.a / 255),
                .a = self.a,
            };
        }

        fn demultiply(self: T) T {
            std.debug.assert(is_rgba);
            if (self.a == 0) return .{ .r = 0, .g = 0, .b = 0, .a = 0 };
            return .{
                .r = @intCast(@as(u16, self.r) * 255 / self.a),
                .g = @intCast(@as(u16, self.g) * 255 / self.a),
                .b = @intCast(@as(u16, self.b) * 255 / self.a),
                .a = self.a,
            };
        }

        fn canDemultiply(self: T) bool {
            std.debug.assert(is_rgba);
            if (self.a == 0) return true;
            inline for (.{ "r", "g", "b" }) |f| {
                if (@as(u16, @field(self, f)) * 255 / self.a > 255) {
                    return false;
                }
            }

            return true;
        }
    };
}

/// Describes a 16-bit RGB format, with 6 bits for the green channel, and 5
/// bits for the red and blue channels.
pub const RGB565 = packed struct(u16) {
    r: u5,
    g: u6,
    b: u5,

    /// The format descriptor for this pixel format.
    pub const format: Format = .rgb565;

    /// Returns a pixel from a clamped 0-1 RGB value.
    pub fn fromClamped(r: f32, g: f32, b: f32) RGB565 {
        const rc = std.math.clamp(r, 0, 1);
        const gc = std.math.clamp(g, 0, 1);
        const bc = std.math.clamp(b, 0, 1);
        return .{
            .r = @intFromFloat(@round(31.0 * rc)),
            .g = @intFromFloat(@round(63.0 * gc)),
            .b = @intFromFloat(@round(31.0 * bc)),
        };
    }

    /// Returns the pixel translated to RGB565.
    pub fn fromPixel(p: Pixel) RGB565 {
        return switch (p) {
            .rgb565 => |q| q,

            // Just shift down all 8-bit values appropriately.
            inline .xrgb, .rgb, .argb, .rgba => |q| fromRGB(.{ .r = q.r, .g = q.g, .b = q.b }),

            inline .rgb24, .bgr24 => |q| fromRGB(.{ .r = q.r(), .g = q.g(), .b = q.b() }),

            // All alpha channels just are black, as per how we convert RGB
            // without alpha.
            inline .alpha8, .alpha4, .alpha2, .alpha1 => .{
                .r = 0,
                .g = 0,
                .b = 0,
            },
        };
    }

    /// Convenience method to convert from 8-bit RGB to RGB565.
    pub fn fromRGB(rgb: RGB) RGB565 {
        return .{
            .r = @intCast(rgb.r >> 3),
            .g = @intCast(rgb.g >> 2),
            .b = @intCast(rgb.b >> 3),
        };
    }

    /// Returns an average of the pixels in the supplied slice. The average of
    /// a zero-length slice is pure black.
    ///
    /// This function is limited to 256 entries; any higher than this is
    /// safety-checked undefined behavior.
    pub fn average(ps: []const RGB565) RGB565 {
        std.debug.assert(ps.len <= 256);
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
    pub fn asPixel(self: RGB565) Pixel {
        return .{ .rgb565 = self };
    }

    /// Convenience method to convert from RGB565 to 8-bit RGB.
    pub fn toRGB(self: RGB565) RGB {
        return .{
            // RGB565 uses the same shift left/right technique as the
            // generic alpha function uses, but just laid out
            // statically we only need to handle two conversions: 5-bit
            // to 8-bit, and 6-bit to 8-bit. See "shlr" in that
            // function for more details.
            .r = @as(u8, self.r) << 3 | @as(u8, self.r) >> 2,
            .g = @as(u8, self.g) << 2 | @as(u8, self.g) >> 4,
            .b = @as(u8, self.b) << 3 | @as(u8, self.b) >> 2,
        };
    }

    /// Returns `true` if the supplied pixels are equal.
    pub fn equal(self: RGB565, other: Pixel) bool {
        return switch (other) {
            .rgb565 => |o| self.r == o.r and self.g == o.g and self.b == o.b,
            else => false,
        };
    }
};

/// Describes an array-backed RGB format, as [3]u8 (order 0=r, 1=g, 2=b).
pub const RGB24 = ArrayU8("rgb");

/// Describes an array-backed BGR format, as [3]u8 (order 0=b, 1=g, 2=r).
pub const BGR24 = ArrayU8("bgr");

/// Generates an array-backed, platform-independent pixel type with the pixels
/// in the specified order.
fn ArrayU8(comptime order: []const u8) type {
    const len = order.len;
    std.debug.assert(len == 3);
    for (0..len) |i| {
        field_validate: {
            for ("rgb") |valid_field| {
                if (order[i] == valid_field) {
                    break :field_validate;
                }
            }

            @compileError("invalid field specified");
        }

        for (0..len) |j| {
            if (i != j and order[i] == order[j]) {
                @compileError("duplicate fields specified");
            }
        }
    }

    return struct {
        const Self = @This();

        /// The format descriptor for this pixel format.
        pub const format: Format = @field(Format, std.fmt.comptimePrint("{s}{d}", .{ order, len * 8 }));

        /// The fields within this pixel type, and the order they show up in.
        /// As an example, `@backingInt(RGB24.Fields.b)` would return `0`.
        pub const Fields = fs: {
            var order_split: [len][]const u8 = undefined;
            var values: [len]u2 = undefined;
            for (0..len) |idx| {
                order_split[idx] = @as([]const u8, @ptrCast(&order[idx]));
                values[idx] = idx;
            }

            break :fs @Enum(u2, .exhaustive, &order_split, &values);
        };

        value: [len]u8,

        /// Initialize a pixel value directly off channel values in the order
        /// they are expected.
        pub fn init(value: [len]u8) Self {
            return .{ .value = value };
        }

        /// Returns the pixel translated to specific pixel type.
        pub fn fromPixel(p: Pixel) Self {
            if (p == format) return @field(p, @tagName(format));

            // Convert to RGB. This is the easiest way we can grab the values
            // we need to possibly set in our byte-fields.
            //
            // TODO: We might actually converge on RGB(A) for most pixel
            // conversion in the future, this may be easier to maintain in the
            // long run. This would be in line with our compositor and
            // everything else running in RGB space as well.
            return fromRGB(RGB.fromPixel(p));
        }

        /// Returns the pixel directly from an `RGB` value.
        pub fn fromRGB(value: RGB) Self {
            var result: [len]u8 = @splat(255); // Accounts for possible alpha value
            const info = @typeInfo(Fields).@"enum";
            inline for (info.field_names, info.field_values) |f_name, f_value| {
                if (std.mem.eql(u8, f_name, "r")) result[f_value] = value.r;
                if (std.mem.eql(u8, f_name, "g")) result[f_value] = value.g;
                if (std.mem.eql(u8, f_name, "b")) result[f_value] = value.b;
            }
            return .{ .value = result };
        }

        /// Returns the pixel directly as an `RGB` value.
        pub fn toRGB(self: Self) RGB {
            return .{
                .r = self.r(),
                .g = self.g(),
                .b = self.b(),
            };
        }

        /// Returns this pixel as an interface.
        pub fn asPixel(self: Self) Pixel {
            return @unionInit(Pixel, @tagName(format), self);
        }

        /// Convenience method to return the pixel's red channel.
        pub fn r(self: Self) u8 {
            return self.value[@backingInt(Self.Fields.r)];
        }

        /// Convenience method to return the pixel's green channel.
        pub fn g(self: Self) u8 {
            return self.value[@backingInt(Self.Fields.g)];
        }

        /// Convenience method to return the pixel's blue channel.
        pub fn b(self: Self) u8 {
            return self.value[@backingInt(Self.Fields.b)];
        }

        /// Convenience method to set the pixel's red channel.
        pub fn setR(self: *Self, value: u8) void {
            self.value[@backingInt(Self.Fields.r)] = value;
        }

        /// Convenience method to set the pixel's green channel.
        pub fn setG(self: *Self, value: u8) void {
            self.value[@backingInt(Self.Fields.g)] = value;
        }

        /// Convenience method to set the pixel's blue channel.
        pub fn setB(self: *Self, value: u8) void {
            self.value[@backingInt(Self.Fields.b)] = value;
        }

        /// Returns `true` if the supplied pixels are equal.
        pub fn equal(self: Self, other: Pixel) bool {
            if (other == format) {
                const o = @field(other, @tagName(format));
                return std.mem.eql(u8, &self.value, &o.value);
            }

            return false;
        }

        /// Returns an average of the pixels in the supplied slice. The average
        /// of a zero-length slice is pure black.
        ///
        /// This function is limited to 256 entries; any higher than this is
        /// safety-checked undefined behavior.
        pub fn average(ps: []const Self) Self {
            std.debug.assert(ps.len <= 256);
            if (ps.len == 0) return .{ .value = @splat(0) };

            var scratch: [len]u16 = @splat(0);
            for (ps) |p| {
                for (0..len) |idx| {
                    scratch[idx] += p.value[idx];
                }
            }

            var result: [len]u8 = undefined;
            for (0..len) |idx| {
                result[idx] = @intCast(scratch[idx] / ps.len);
            }

            return .{ .value = result };
        }
    };
}

/// Describes an 8-bit alpha channel-only format.
pub const Alpha8 = Alpha(.alpha8);

/// Describes a 4-bit alpha channel-only format.
pub const Alpha4 = Alpha(.alpha4);

/// Describes a 2-bit alpha channel-only format.
pub const Alpha2 = Alpha(.alpha2);

/// Describes a 1-bit alpha channel-only format.
pub const Alpha1 = Alpha(.alpha1);

comptime {
    std.debug.assert(@bitSizeOf(Alpha8) == 8);
    std.debug.assert(@bitSizeOf(Alpha4) == 4);
    std.debug.assert(@bitSizeOf(Alpha2) == 2);
    std.debug.assert(@bitSizeOf(Alpha1) == 1);

    // All alpha types have an alignment of 1. Types that have a bit size lower
    // than 8 (1 byte) are stored in packed-bit surfaces, so alignment should
    // still be a full byte.
    std.debug.assert(@alignOf(Alpha8) == 1);
    std.debug.assert(@alignOf(Alpha4) == 1);
    std.debug.assert(@alignOf(Alpha2) == 1);
    std.debug.assert(@alignOf(Alpha1) == 1);
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
        pub const IntType = @Int(.unsigned, NumBits);

        /// The format descriptor for this pixel format.
        pub const format: Format = fmt;

        /// Shorthand for a fully-opaque pixel in this format.
        pub const Opaque: Self = @bitCast(MaxInt);

        /// Returns the pixel translated to the alpha format.
        pub fn fromPixel(p: Pixel) Self {
            return switch (p) {
                .xrgb, .rgb, .rgb24, .bgr24, .rgb565 => .{
                    // Special case: we assume that RGB pixels are always opaque
                    .a = MaxInt,
                },
                inline else => |q| .{ .a = scaleIntoIntAlpha(q.a) },
            };
        }

        /// Low-level primitive used to scale up/down alpha bytes, uses
        /// repeating-bit padding when scaling up. Not recommended for external
        /// use (use `fromPixel` instead).
        pub fn scaleIntoIntAlpha(val: anytype) IntType {
            if (@typeInfo(@TypeOf(val)).int.bits == 1) return val * MaxInt;
            return shlr(IntType, val);
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
            std.debug.assert(ps.len <= 256);
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
            comptime std.debug.assert(NumBits < 8);
            const px_int = std.mem.readPackedInt(IntType, buf, index * @bitSizeOf(IntType), .little);
            return @bitCast(px_int);
        }

        /// Utility function to set a pixel in a supplied packed buffer. Only
        /// available for packed types, for non-packed types (e.g., `Alpha8`),
        /// use standard indexing.
        pub fn setInPacked(buf: []u8, index: usize, value: Self) void {
            comptime std.debug.assert(NumBits < 8);
            const px_int = @as(IntType, @bitCast(value));
            std.mem.writePackedInt(IntType, buf, index * @bitSizeOf(IntType), px_int, .little);
        }
    };
}

test "pixel interface, asPixel" {
    const argb: ARGB = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC, .a = 0xDD };
    const xrgb: XRGB = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC };
    const rgb: RGB = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC };
    const rgba: RGBA = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC, .a = 0xDD };
    const rgb24: RGB24 = .init(.{ 0xAA, 0xBB, 0xCC });
    const bgr24: BGR24 = .init(.{ 0xAA, 0xBB, 0xCC });
    const rgb565: RGB565 = .{ .r = 28, .g = 56, .b = 21 };
    const alpha8: Alpha8 = .{ .a = 0xDD };
    const alpha4: Alpha4 = .{ .a = 0xD };
    const alpha2: Alpha2 = .{ .a = 2 };
    const alpha1: Alpha1 = .{ .a = 1 };

    try std.testing.expectEqual(Pixel{ .argb = argb }, argb.asPixel());
    try std.testing.expectEqual(Pixel{ .xrgb = xrgb }, xrgb.asPixel());
    try std.testing.expectEqual(Pixel{ .rgb = rgb }, rgb.asPixel());
    try std.testing.expectEqual(Pixel{ .rgba = rgba }, rgba.asPixel());
    try std.testing.expectEqual(Pixel{ .rgb24 = rgb24 }, rgb24.asPixel());
    try std.testing.expectEqual(Pixel{ .bgr24 = bgr24 }, bgr24.asPixel());
    try std.testing.expectEqual(Pixel{ .rgb565 = rgb565 }, rgb565.asPixel());
    try std.testing.expectEqual(Pixel{ .alpha8 = alpha8 }, alpha8.asPixel());
    try std.testing.expectEqual(Pixel{ .alpha4 = alpha4 }, alpha4.asPixel());
    try std.testing.expectEqual(Pixel{ .alpha2 = alpha2 }, alpha2.asPixel());
    try std.testing.expectEqual(Pixel{ .alpha1 = alpha1 }, alpha1.asPixel());
}

test "pixel interface, average" {
    const argb = [_]ARGB{
        .{ .r = 1, .g = 5, .b = 9, .a = 13 },
        .{ .r = 2, .g = 6, .b = 10, .a = 14 },
        .{ .r = 3, .g = 7, .b = 11, .a = 15 },
        .{ .r = 4, .g = 8, .b = 12, .a = 16 },
    };
    const argb_expected: ARGB = .{ .r = 2, .g = 6, .b = 10, .a = 14 };

    const xrgb = [_]XRGB{
        .{ .r = 1, .g = 5, .b = 9 },
        .{ .r = 2, .g = 6, .b = 10 },
        .{ .r = 3, .g = 7, .b = 11 },
        .{ .r = 4, .g = 8, .b = 12 },
    };
    const xrgb_expected: XRGB = .{ .r = 2, .g = 6, .b = 10 };

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

    const rgb24 = [_]RGB24{
        .init(.{ 1, 5, 9 }),
        .init(.{ 2, 6, 10 }),
        .init(.{ 3, 7, 11 }),
        .init(.{ 4, 8, 12 }),
    };
    const rgb24_expected: RGB24 = .{ .value = .{ 2, 6, 10 } };

    const bgr24 = [_]BGR24{
        .init(.{ 1, 5, 9 }),
        .init(.{ 2, 6, 10 }),
        .init(.{ 3, 7, 11 }),
        .init(.{ 4, 8, 12 }),
    };
    const bgr24_expected: BGR24 = .{ .value = .{ 2, 6, 10 } };

    const rgb565 = [_]RGB565{
        .{ .r = 1, .g = 5, .b = 9 },
        .{ .r = 2, .g = 6, .b = 10 },
        .{ .r = 3, .g = 7, .b = 11 },
        .{ .r = 4, .g = 8, .b = 12 },
    };
    const rgb565_expected: RGB565 = .{ .r = 2, .g = 6, .b = 10 };

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

    try std.testing.expectEqual(argb_expected, ARGB.average(&argb));
    try std.testing.expectEqual(xrgb_expected, XRGB.average(&xrgb));
    try std.testing.expectEqual(rgb_expected, RGB.average(&rgb));
    try std.testing.expectEqual(rgba_expected, RGBA.average(&rgba));
    try std.testing.expectEqual(rgb24_expected, RGB24.average(&rgb24));
    try std.testing.expectEqual(bgr24_expected, BGR24.average(&bgr24));
    try std.testing.expectEqual(rgb565_expected, RGB565.average(&rgb565));
    try std.testing.expectEqual(alpha8_expected, Alpha8.average(&alpha8));
    try std.testing.expectEqual(alpha4_expected, Alpha4.average(&alpha4));
    try std.testing.expectEqual(alpha2_expected, Alpha2.average(&alpha2));
    try std.testing.expectEqual(alpha1_full_expected, Alpha1.average(&alpha1_full));
    try std.testing.expectEqual(alpha1_partial_expected, Alpha1.average(&alpha1_partial));
}

test "ARGB/RGBA, multiply/demultiply" {
    {
        // Note that multiply/demultiply calls are NOT reversible, due to remainder
        // loss. The test below reflects that.
        // AA = 170, BB = 187, CC = 204
        inline for (.{ ARGB, RGBA }) |T| {
            const rgba: T = .{ .r = 170, .g = 187, .b = 204, .a = 128 };
            const expected_multiplied: T = .{ .r = 85, .g = 93, .b = 102, .a = 128 };
            const expected_demultiplied: T = .{ .r = 169, .g = 185, .b = 203, .a = 128 };

            try std.testing.expectEqual(expected_multiplied, rgba.multiply());
            try std.testing.expectEqual(expected_demultiplied, expected_multiplied.demultiply());
        }
    }

    {
        // Handling zero alpha
        inline for (.{ ARGB, RGBA }) |T| {
            const rgba: T = .{ .r = 170, .g = 187, .b = 204, .a = 0 };
            const expected_multiplied: T = .{ .r = 0, .g = 0, .b = 0, .a = 0 };

            try std.testing.expectEqual(expected_multiplied, rgba.multiply());
            try std.testing.expectEqual(expected_multiplied, expected_multiplied.demultiply());
        }
    }
}

test "XRGB/RGB, fromClamped" {
    inline for (.{ XRGB, RGB }) |T| {
        try std.testing.expectEqual(T{ .r = 77, .g = 153, .b = 230 }, T.fromClamped(0.3, 0.6, 0.9));
        try std.testing.expectEqual(T{ .r = 0, .g = 0, .b = 0 }, T.fromClamped(-1, -1, -1));
        try std.testing.expectEqual(T{ .r = 255, .g = 255, .b = 255 }, T.fromClamped(2, 2, 2));
    }
}

test "ARGB/RGBA, fromClamped" {
    inline for (.{ ARGB, RGBA }) |T| {
        try std.testing.expectEqual(
            T{ .r = 77, .g = 153, .b = 230, .a = 255 },
            T.fromClamped(0.3, 0.6, 0.9, 1),
        );
        try std.testing.expectEqual(
            T{ .r = 38, .g = 76, .b = 115, .a = 128 },
            T.fromClamped(0.3, 0.6, 0.9, 0.5),
        );
        try std.testing.expectEqual(
            T{ .r = 0, .g = 0, .b = 0, .a = 0 },
            T.fromClamped(-1, -1, -1, -1),
        );
        try std.testing.expectEqual(
            T{ .r = 255, .g = 255, .b = 255, .a = 255 },
            T.fromClamped(2, 2, 2, 2),
        );
        try std.testing.expectEqual(
            T{ .r = 128, .g = 128, .b = 128, .a = 128 },
            T.fromClamped(2, 2, 2, 0.5),
        );
    }
}

test "RGB565, fromClamped" {
    try std.testing.expectEqual(RGB565{ .r = 9, .g = 38, .b = 28 }, RGB565.fromClamped(0.3, 0.6, 0.9));
    try std.testing.expectEqual(RGB565{ .r = 0, .g = 0, .b = 0 }, RGB565.fromClamped(-1, -1, -1));
    try std.testing.expectEqual(RGB565{ .r = 31, .g = 63, .b = 31 }, RGB565.fromClamped(2, 2, 2));
}

test "fromPixel" {
    const Pair = struct {
        a: Pixel,
        b: Pixel,
    };
    const name = "fromPixel";
    const cases = [_]struct {
        name: []const u8,
        pairs: []const Pair,
    }{
        .{
            .name = "argb",
            .pairs = &.{
                .{
                    .a = .{ .argb = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC, .a = 0xDD } },
                    .b = .{ .argb = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC, .a = 0xDD } },
                },
                .{
                    .a = .{ .argb = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC, .a = 0xFF } },
                    .b = .{ .xrgb = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC } },
                },
                .{
                    .a = .{ .argb = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC, .a = 0xFF } },
                    .b = .{ .rgb = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC } },
                },
                .{
                    .a = .{ .argb = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC, .a = 0xDD } },
                    .b = .{ .rgba = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC, .a = 0xDD } },
                },
                .{
                    .a = .{ .argb = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC, .a = 0xFF } },
                    .b = .{ .rgb24 = .{ .value = .{ 0xAA, 0xBB, 0xCC } } },
                },
                .{
                    .a = .{ .argb = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC, .a = 0xFF } },
                    .b = .{ .bgr24 = .{ .value = .{ 0xCC, 0xBB, 0xAA } } },
                },
                .{
                    .a = .{ .argb = .{ .r = 231, .g = 227, .b = 173, .a = 255 } },
                    .b = .{ .rgb565 = .{ .r = 28, .g = 56, .b = 21 } },
                },
                .{
                    .a = .{ .argb = .{ .r = 0x00, .g = 0x00, .b = 0x00, .a = 0xDD } },
                    .b = .{ .alpha8 = .{ .a = 0xDD } },
                },
                .{
                    .a = .{ .argb = .{ .r = 0x00, .g = 0x00, .b = 0x00, .a = 0xDD } },
                    .b = .{ .alpha4 = .{ .a = 0xD } },
                },
                .{
                    .a = .{ .argb = .{ .r = 0x00, .g = 0x00, .b = 0x00, .a = 0xFF } },
                    .b = .{ .alpha2 = .{ .a = 3 } },
                },
                .{
                    .a = .{ .argb = .{ .r = 0x00, .g = 0x00, .b = 0x00, .a = 0xFF } },
                    .b = .{ .alpha1 = .{ .a = 1 } },
                },
            },
        },
        .{
            .name = "xrgb",
            .pairs = &.{
                .{
                    .a = .{ .xrgb = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC } },
                    .b = .{ .argb = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC, .a = 0xDD } },
                },
                .{
                    .a = .{ .xrgb = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC } },
                    .b = .{ .xrgb = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC } },
                },
                .{
                    .a = .{ .xrgb = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC } },
                    .b = .{ .rgb = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC } },
                },
                .{
                    .a = .{ .xrgb = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC } },
                    .b = .{ .rgba = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC, .a = 0xDD } },
                },
                .{
                    .a = .{ .xrgb = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC } },
                    .b = .{ .rgb24 = .{ .value = .{ 0xAA, 0xBB, 0xCC } } },
                },
                .{
                    .a = .{ .xrgb = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC } },
                    .b = .{ .bgr24 = .{ .value = .{ 0xCC, 0xBB, 0xAA } } },
                },
                .{
                    .a = .{ .xrgb = .{ .r = 231, .g = 227, .b = 173 } },
                    .b = .{ .rgb565 = .{ .r = 28, .g = 56, .b = 21 } },
                },
                .{
                    .a = .{ .xrgb = .{ .r = 0x00, .g = 0x00, .b = 0x00 } },
                    .b = .{ .alpha8 = .{ .a = 0xDD } },
                },
                .{
                    .a = .{ .xrgb = .{ .r = 0x00, .g = 0x00, .b = 0x00 } },
                    .b = .{ .alpha4 = .{ .a = 0xD } },
                },
                .{
                    .a = .{ .xrgb = .{ .r = 0x00, .g = 0x00, .b = 0x00 } },
                    .b = .{ .alpha2 = .{ .a = 3 } },
                },
                .{
                    .a = .{ .xrgb = .{ .r = 0x00, .g = 0x00, .b = 0x00 } },
                    .b = .{ .alpha1 = .{ .a = 1 } },
                },
            },
        },
        .{
            .name = "rgb",
            .pairs = &.{
                .{
                    .a = .{ .rgb = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC } },
                    .b = .{ .argb = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC, .a = 0xDD } },
                },
                .{
                    .a = .{ .rgb = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC } },
                    .b = .{ .xrgb = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC } },
                },
                .{
                    .a = .{ .rgb = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC } },
                    .b = .{ .rgb = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC } },
                },
                .{
                    .a = .{ .rgb = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC } },
                    .b = .{ .rgba = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC, .a = 0xDD } },
                },
                .{
                    .a = .{ .rgb = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC } },
                    .b = .{ .rgb24 = .{ .value = .{ 0xAA, 0xBB, 0xCC } } },
                },
                .{
                    .a = .{ .rgb = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC } },
                    .b = .{ .bgr24 = .{ .value = .{ 0xCC, 0xBB, 0xAA } } },
                },
                .{
                    .a = .{ .rgb = .{ .r = 231, .g = 227, .b = 173 } },
                    .b = .{ .rgb565 = .{ .r = 28, .g = 56, .b = 21 } },
                },
                .{
                    .a = .{ .rgb = .{ .r = 0x00, .g = 0x00, .b = 0x00 } },
                    .b = .{ .alpha8 = .{ .a = 0xDD } },
                },
                .{
                    .a = .{ .rgb = .{ .r = 0x00, .g = 0x00, .b = 0x00 } },
                    .b = .{ .alpha4 = .{ .a = 0xD } },
                },
                .{
                    .a = .{ .rgb = .{ .r = 0x00, .g = 0x00, .b = 0x00 } },
                    .b = .{ .alpha2 = .{ .a = 3 } },
                },
                .{
                    .a = .{ .rgb = .{ .r = 0x00, .g = 0x00, .b = 0x00 } },
                    .b = .{ .alpha1 = .{ .a = 1 } },
                },
            },
        },
        .{
            .name = "rgba",
            .pairs = &.{
                .{
                    .a = .{ .rgba = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC, .a = 0xDD } },
                    .b = .{ .argb = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC, .a = 0xDD } },
                },
                .{
                    .a = .{ .rgba = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC, .a = 0xFF } },
                    .b = .{ .xrgb = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC } },
                },
                .{
                    .a = .{ .rgba = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC, .a = 0xFF } },
                    .b = .{ .rgb = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC } },
                },
                .{
                    .a = .{ .rgba = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC, .a = 0xDD } },
                    .b = .{ .rgba = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC, .a = 0xDD } },
                },
                .{
                    .a = .{ .rgba = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC, .a = 0xFF } },
                    .b = .{ .rgb24 = .{ .value = .{ 0xAA, 0xBB, 0xCC } } },
                },
                .{
                    .a = .{ .rgba = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC, .a = 0xFF } },
                    .b = .{ .bgr24 = .{ .value = .{ 0xCC, 0xBB, 0xAA } } },
                },
                .{
                    .a = .{ .rgba = .{ .r = 231, .g = 227, .b = 173, .a = 255 } },
                    .b = .{ .rgb565 = .{ .r = 28, .g = 56, .b = 21 } },
                },
                .{
                    .a = .{ .rgba = .{ .r = 0x00, .g = 0x00, .b = 0x00, .a = 0xDD } },
                    .b = .{ .alpha8 = .{ .a = 0xDD } },
                },
                .{
                    .a = .{ .rgba = .{ .r = 0x00, .g = 0x00, .b = 0x00, .a = 0xDD } },
                    .b = .{ .alpha4 = .{ .a = 0xD } },
                },
                .{
                    .a = .{ .rgba = .{ .r = 0x00, .g = 0x00, .b = 0x00, .a = 0xFF } },
                    .b = .{ .alpha2 = .{ .a = 3 } },
                },
                .{
                    .a = .{ .rgba = .{ .r = 0x00, .g = 0x00, .b = 0x00, .a = 0xFF } },
                    .b = .{ .alpha1 = .{ .a = 1 } },
                },
            },
        },
        .{
            .name = "rgb24",
            .pairs = &.{
                .{
                    .a = .{ .rgb24 = .{ .value = .{ 0xAA, 0xBB, 0xCC } } },
                    .b = .{ .argb = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC, .a = 0xDD } },
                },
                .{
                    .a = .{ .rgb24 = .{ .value = .{ 0xAA, 0xBB, 0xCC } } },
                    .b = .{ .xrgb = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC } },
                },
                .{
                    .a = .{ .rgb24 = .{ .value = .{ 0xAA, 0xBB, 0xCC } } },
                    .b = .{ .rgb = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC } },
                },
                .{
                    .a = .{ .rgb24 = .{ .value = .{ 0xAA, 0xBB, 0xCC } } },
                    .b = .{ .rgba = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC, .a = 0xDD } },
                },
                .{
                    .a = .{ .rgb24 = .{ .value = .{ 0xAA, 0xBB, 0xCC } } },
                    .b = .{ .rgb24 = .{ .value = .{ 0xAA, 0xBB, 0xCC } } },
                },
                .{
                    .a = .{ .rgb24 = .{ .value = .{ 0xAA, 0xBB, 0xCC } } },
                    .b = .{ .bgr24 = .{ .value = .{ 0xCC, 0xBB, 0xAA } } },
                },
                .{
                    .a = .{ .rgb24 = .{ .value = .{ 231, 227, 173 } } },
                    .b = .{ .rgb565 = .{ .r = 28, .g = 56, .b = 21 } },
                },
                .{
                    .a = .{ .rgb24 = .{ .value = .{ 0x00, 0x00, 0x00 } } },
                    .b = .{ .alpha8 = .{ .a = 0xDD } },
                },
                .{
                    .a = .{ .rgb24 = .{ .value = .{ 0x00, 0x00, 0x00 } } },
                    .b = .{ .alpha4 = .{ .a = 0xD } },
                },
                .{
                    .a = .{ .rgb24 = .{ .value = .{ 0x00, 0x00, 0x00 } } },
                    .b = .{ .alpha2 = .{ .a = 3 } },
                },
                .{
                    .a = .{ .rgb24 = .{ .value = .{ 0x00, 0x00, 0x00 } } },
                    .b = .{ .alpha1 = .{ .a = 1 } },
                },
            },
        },
        .{
            .name = "bgr24",
            .pairs = &.{
                .{
                    .a = .{ .bgr24 = .{ .value = .{ 0xCC, 0xBB, 0xAA } } },
                    .b = .{ .argb = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC, .a = 0xDD } },
                },
                .{
                    .a = .{ .bgr24 = .{ .value = .{ 0xCC, 0xBB, 0xAA } } },
                    .b = .{ .xrgb = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC } },
                },
                .{
                    .a = .{ .bgr24 = .{ .value = .{ 0xCC, 0xBB, 0xAA } } },
                    .b = .{ .rgb = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC } },
                },
                .{
                    .a = .{ .bgr24 = .{ .value = .{ 0xCC, 0xBB, 0xAA } } },
                    .b = .{ .rgba = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC, .a = 0xDD } },
                },
                .{
                    .a = .{ .bgr24 = .{ .value = .{ 0xCC, 0xBB, 0xAA } } },
                    .b = .{ .rgb24 = .{ .value = .{ 0xAA, 0xBB, 0xCC } } },
                },
                .{
                    .a = .{ .bgr24 = .{ .value = .{ 0xCC, 0xBB, 0xAA } } },
                    .b = .{ .bgr24 = .{ .value = .{ 0xCC, 0xBB, 0xAA } } },
                },
                .{
                    .a = .{ .bgr24 = .{ .value = .{ 173, 227, 231 } } },
                    .b = .{ .rgb565 = .{ .r = 28, .g = 56, .b = 21 } },
                },
                .{
                    .a = .{ .bgr24 = .{ .value = .{ 0x00, 0x00, 0x00 } } },
                    .b = .{ .alpha8 = .{ .a = 0xDD } },
                },
                .{
                    .a = .{ .bgr24 = .{ .value = .{ 0x00, 0x00, 0x00 } } },
                    .b = .{ .alpha4 = .{ .a = 0xD } },
                },
                .{
                    .a = .{ .bgr24 = .{ .value = .{ 0x00, 0x00, 0x00 } } },
                    .b = .{ .alpha2 = .{ .a = 3 } },
                },
                .{
                    .a = .{ .bgr24 = .{ .value = .{ 0x00, 0x00, 0x00 } } },
                    .b = .{ .alpha1 = .{ .a = 1 } },
                },
            },
        },
        .{
            .name = "rgb565",
            .pairs = &.{
                .{
                    .a = .{ .rgb565 = .{ .r = 28, .g = 56, .b = 21 } },
                    .b = .{ .argb = .{ .r = 231, .g = 227, .b = 173, .a = 255 } },
                },
                .{
                    .a = .{ .rgb565 = .{ .r = 28, .g = 56, .b = 21 } },
                    .b = .{ .xrgb = .{ .r = 231, .g = 227, .b = 173 } },
                },
                .{
                    .a = .{ .rgb565 = .{ .r = 28, .g = 56, .b = 21 } },
                    .b = .{ .rgb = .{ .r = 231, .g = 227, .b = 173 } },
                },
                .{
                    .a = .{ .rgb565 = .{ .r = 28, .g = 56, .b = 21 } },
                    .b = .{ .rgba = .{ .r = 231, .g = 227, .b = 173, .a = 255 } },
                },
                .{
                    .a = .{ .rgb565 = .{ .r = 28, .g = 56, .b = 21 } },
                    .b = .{ .rgb24 = .{ .value = .{ 231, 227, 173 } } },
                },
                .{
                    .a = .{ .rgb565 = .{ .r = 28, .g = 56, .b = 21 } },
                    .b = .{ .bgr24 = .{ .value = .{ 173, 227, 231 } } },
                },
                .{
                    .a = .{ .rgb565 = .{ .r = 28, .g = 56, .b = 21 } },
                    .b = .{ .rgb565 = .{ .r = 28, .g = 56, .b = 21 } },
                },
                .{
                    .a = .{ .rgb565 = .{ .r = 0, .g = 0, .b = 0 } },
                    .b = .{ .alpha8 = .{ .a = 255 } },
                },
                .{
                    .a = .{ .rgb565 = .{ .r = 0, .g = 0, .b = 0 } },
                    .b = .{ .alpha4 = .{ .a = 15 } },
                },
                .{
                    .a = .{ .rgb565 = .{ .r = 0, .g = 0, .b = 0 } },
                    .b = .{ .alpha2 = .{ .a = 3 } },
                },
                .{
                    .a = .{ .rgb565 = .{ .r = 0, .g = 0, .b = 0 } },
                    .b = .{ .alpha1 = .{ .a = 1 } },
                },
            },
        },
        .{
            .name = "alpha8",
            .pairs = &.{
                .{
                    .a = .{ .alpha8 = .{ .a = 0xDD } },
                    .b = .{ .argb = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC, .a = 0xDD } },
                },
                .{
                    .a = .{ .alpha8 = .{ .a = 0xFF } },
                    .b = .{ .xrgb = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC } },
                },
                .{
                    .a = .{ .alpha8 = .{ .a = 0xFF } },
                    .b = .{ .rgb = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC } },
                },
                .{
                    .a = .{ .alpha8 = .{ .a = 0xDD } },
                    .b = .{ .rgba = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC, .a = 0xDD } },
                },
                .{
                    .a = .{ .alpha8 = .{ .a = 0xFF } },
                    .b = .{ .rgb24 = .{ .value = .{ 0xAA, 0xBB, 0xCC } } },
                },
                .{
                    .a = .{ .alpha8 = .{ .a = 0xFF } },
                    .b = .{ .bgr24 = .{ .value = .{ 0xCC, 0xBB, 0xAA } } },
                },
                .{
                    .a = .{ .alpha8 = .{ .a = 0xFF } },
                    .b = .{ .rgb565 = .{ .r = 28, .g = 56, .b = 21 } },
                },
                .{
                    .a = .{ .alpha8 = .{ .a = 0xDD } },
                    .b = .{ .alpha8 = .{ .a = 0xDD } },
                },
                .{
                    .a = .{ .alpha8 = .{ .a = 0xDD } },
                    .b = .{ .alpha4 = .{ .a = 0xD } },
                },
                .{
                    .a = .{ .alpha8 = .{ .a = 0xFF } },
                    .b = .{ .alpha2 = .{ .a = 3 } },
                },
                .{
                    .a = .{ .alpha8 = .{ .a = 0xFF } },
                    .b = .{ .alpha1 = .{ .a = 1 } },
                },
            },
        },
        .{
            .name = "alpha4",
            .pairs = &.{
                .{
                    .a = .{ .alpha4 = .{ .a = 0xD } },
                    .b = .{ .argb = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC, .a = 0xDD } },
                },
                .{
                    .a = .{ .alpha4 = .{ .a = 0xF } },
                    .b = .{ .xrgb = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC } },
                },
                .{
                    .a = .{ .alpha4 = .{ .a = 0xF } },
                    .b = .{ .rgb = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC } },
                },
                .{
                    .a = .{ .alpha4 = .{ .a = 0xD } },
                    .b = .{ .rgba = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC, .a = 0xDD } },
                },
                .{
                    .a = .{ .alpha4 = .{ .a = 0xF } },
                    .b = .{ .rgb24 = .{ .value = .{ 0xAA, 0xBB, 0xCC } } },
                },
                .{
                    .a = .{ .alpha4 = .{ .a = 0xF } },
                    .b = .{ .bgr24 = .{ .value = .{ 0xCC, 0xBB, 0xAA } } },
                },
                .{
                    .a = .{ .alpha4 = .{ .a = 0xF } },
                    .b = .{ .rgb565 = .{ .r = 28, .g = 56, .b = 21 } },
                },
                .{
                    .a = .{ .alpha4 = .{ .a = 0xD } },
                    .b = .{ .alpha8 = .{ .a = 0xDD } },
                },
                .{
                    .a = .{ .alpha4 = .{ .a = 0xD } },
                    .b = .{ .alpha4 = .{ .a = 0xD } },
                },
                .{
                    .a = .{ .alpha4 = .{ .a = 0xF } },
                    .b = .{ .alpha2 = .{ .a = 3 } },
                },
                .{
                    .a = .{ .alpha4 = .{ .a = 0xF } },
                    .b = .{ .alpha1 = .{ .a = 1 } },
                },
            },
        },
        .{
            .name = "alpha2",
            .pairs = &.{
                .{
                    .a = .{ .alpha2 = .{ .a = 2 } },
                    .b = .{ .argb = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC, .a = 0xA0 } },
                },
                .{
                    .a = .{ .alpha2 = .{ .a = 3 } },
                    .b = .{ .xrgb = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC } },
                },
                .{
                    .a = .{ .alpha2 = .{ .a = 3 } },
                    .b = .{ .rgb = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC } },
                },
                .{
                    .a = .{ .alpha2 = .{ .a = 2 } },
                    .b = .{ .rgba = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC, .a = 0xA0 } },
                },
                .{
                    .a = .{ .alpha2 = .{ .a = 3 } },
                    .b = .{ .rgb24 = .{ .value = .{ 0xAA, 0xBB, 0xCC } } },
                },
                .{
                    .a = .{ .alpha2 = .{ .a = 3 } },
                    .b = .{ .bgr24 = .{ .value = .{ 0xCC, 0xBB, 0xAA } } },
                },
                .{
                    .a = .{ .alpha2 = .{ .a = 3 } },
                    .b = .{ .rgb565 = .{ .r = 28, .g = 56, .b = 21 } },
                },
                .{
                    .a = .{ .alpha2 = .{ .a = 2 } },
                    .b = .{ .alpha8 = .{ .a = 0xA0 } },
                },
                .{
                    .a = .{ .alpha2 = .{ .a = 2 } },
                    .b = .{ .alpha4 = .{ .a = 0xA } },
                },
                .{
                    .a = .{ .alpha2 = .{ .a = 3 } },
                    .b = .{ .alpha2 = .{ .a = 3 } },
                },
                .{
                    .a = .{ .alpha2 = .{ .a = 3 } },
                    .b = .{ .alpha1 = .{ .a = 1 } },
                },
            },
        },
        .{
            .name = "alpha1",
            .pairs = &.{
                .{
                    .a = .{ .alpha1 = .{ .a = 1 } },
                    .b = .{ .argb = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC, .a = 0xA0 } },
                },
                .{
                    .a = .{ .alpha1 = .{ .a = 1 } },
                    .b = .{ .xrgb = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC } },
                },
                .{
                    .a = .{ .alpha1 = .{ .a = 1 } },
                    .b = .{ .rgb = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC } },
                },
                .{
                    .a = .{ .alpha1 = .{ .a = 1 } },
                    .b = .{ .rgba = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC, .a = 0xA0 } },
                },
                .{
                    .a = .{ .alpha1 = .{ .a = 1 } },
                    .b = .{ .rgb24 = .{ .value = .{ 0xAA, 0xBB, 0xCC } } },
                },
                .{
                    .a = .{ .alpha1 = .{ .a = 1 } },
                    .b = .{ .bgr24 = .{ .value = .{ 0xCC, 0xBB, 0xAA } } },
                },
                .{
                    .a = .{ .alpha1 = .{ .a = 1 } },
                    .b = .{ .rgb565 = .{ .r = 28, .g = 56, .b = 21 } },
                },
                .{
                    .a = .{ .alpha1 = .{ .a = 1 } },
                    .b = .{ .alpha8 = .{ .a = 0xA0 } },
                },
                .{
                    .a = .{ .alpha1 = .{ .a = 1 } },
                    .b = .{ .alpha4 = .{ .a = 0xA } },
                },
                .{
                    .a = .{ .alpha1 = .{ .a = 1 } },
                    .b = .{ .alpha2 = .{ .a = 3 } },
                },
                .{
                    .a = .{ .alpha1 = .{ .a = 1 } },
                    .b = .{ .alpha1 = .{ .a = 1 } },
                },
            },
        },
    };
    const TestFn = struct {
        fn f(tc: anytype) TestingError!void {
            // fromPixel
            for (tc.pairs, 0..) |pair, idx| {
                switch (pair.a) {
                    inline else => |expected| {
                        std.testing.expectEqualDeep(expected, @TypeOf(expected).fromPixel(pair.b)) catch |err| {
                            std.debug.print("index {d}: mismatch detected.\n", .{idx});
                            return err;
                        };
                    },
                }
            }
        }
    };
    try runCases(name, cases, TestFn.f);
}

test "Alpha, shlr" {
    // This only instantiates the type, shlr only exists in the namespace.
    const test_T = Alpha(.alpha8);
    {
        // zero
        try std.testing.expectEqual(0, test_T.shlr(u8, 0));
    }

    {
        // equal types
        try std.testing.expectEqual(255, test_T.shlr(u8, @as(u8, 255)));
    }

    {
        // shift down
        try std.testing.expectEqual(15, test_T.shlr(u4, @as(u8, 255)));
        try std.testing.expectEqual(3, test_T.shlr(u2, @as(u8, 255)));
        try std.testing.expectEqual(1, test_T.shlr(u1, @as(u8, 255)));
        try std.testing.expectEqual(0, test_T.shlr(u1, @as(u8, 127)));

        try std.testing.expectEqual(3, test_T.shlr(u2, @as(u4, 15)));
        try std.testing.expectEqual(1, test_T.shlr(u2, @as(u4, 4)));
        try std.testing.expectEqual(0, test_T.shlr(u2, @as(u4, 3)));
        try std.testing.expectEqual(1, test_T.shlr(u1, @as(u4, 15)));
        try std.testing.expectEqual(0, test_T.shlr(u1, @as(u4, 7)));

        try std.testing.expectEqual(1, test_T.shlr(u1, @as(u2, 3)));
        try std.testing.expectEqual(0, test_T.shlr(u1, @as(u2, 1)));
    }

    {
        // shift up (u2)
        try std.testing.expectEqual(5, test_T.shlr(u4, @as(u2, 1)));
        try std.testing.expectEqual(10, test_T.shlr(u4, @as(u2, 2)));
        try std.testing.expectEqual(15, test_T.shlr(u4, @as(u2, 3)));

        try std.testing.expectEqual(85, test_T.shlr(u8, @as(u2, 1)));
        try std.testing.expectEqual(170, test_T.shlr(u8, @as(u2, 2)));
        try std.testing.expectEqual(255, test_T.shlr(u8, @as(u2, 3)));
    }

    {
        // shift up (u4)
        try std.testing.expectEqual(17, test_T.shlr(u8, @as(u4, 1)));
        try std.testing.expectEqual(34, test_T.shlr(u8, @as(u4, 2)));
        try std.testing.expectEqual(51, test_T.shlr(u8, @as(u4, 3)));
        try std.testing.expectEqual(68, test_T.shlr(u8, @as(u4, 4)));
        try std.testing.expectEqual(85, test_T.shlr(u8, @as(u4, 5)));
        try std.testing.expectEqual(102, test_T.shlr(u8, @as(u4, 6)));
        try std.testing.expectEqual(119, test_T.shlr(u8, @as(u4, 7)));
        try std.testing.expectEqual(136, test_T.shlr(u8, @as(u4, 8)));
        try std.testing.expectEqual(153, test_T.shlr(u8, @as(u4, 9)));
        try std.testing.expectEqual(170, test_T.shlr(u8, @as(u4, 10)));
        try std.testing.expectEqual(187, test_T.shlr(u8, @as(u4, 11)));
        try std.testing.expectEqual(204, test_T.shlr(u8, @as(u4, 12)));
        try std.testing.expectEqual(221, test_T.shlr(u8, @as(u4, 13)));
        try std.testing.expectEqual(238, test_T.shlr(u8, @as(u4, 14)));
        try std.testing.expectEqual(255, test_T.shlr(u8, @as(u4, 15)));
    }

    {
        // invalid cases that (deliberately) generate compile errors
        //
        // NOTE: This is commented out since we cannot test compile errors
        // currently. Comment out to test ad-hoc. There's an accepted Zig
        // proposal for this so once it will get implemented eventually, after
        // which we can enable permanently.
        //
        // try std.testing.expectEqual(255, test_T.shlr(u8, @as(u1, 1)));
    }
}

test "equal" {
    const name = "equal";
    const cases = [_]struct {
        name: []const u8,
        a: Pixel,
        b: Pixel,
        other: Pixel,
    }{
        .{
            .name = "argb",
            .a = .{ .argb = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC, .a = 0xDD } },
            .b = .{ .argb = .{ .r = 0x11, .g = 0x22, .b = 0x33, .a = 0x44 } },
            .other = .{ .xrgb = .{ .r = 0x11, .g = 0x22, .b = 0x33 } },
        },
        .{
            .name = "xrgb",
            .a = .{ .xrgb = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC } },
            .b = .{ .xrgb = .{ .r = 0x11, .g = 0x22, .b = 0x33 } },
            .other = .{ .argb = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC, .a = 0xDD } },
        },
        .{
            .name = "rgb",
            .a = .{ .rgb = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC } },
            .b = .{ .rgb = .{ .r = 0x11, .g = 0x22, .b = 0x33 } },
            .other = .{ .argb = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC, .a = 0xDD } },
        },
        .{
            .name = "rgba",
            .a = .{ .rgba = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC, .a = 0xDD } },
            .b = .{ .rgba = .{ .r = 0x11, .g = 0x22, .b = 0x33, .a = 0x44 } },
            .other = .{ .xrgb = .{ .r = 0x11, .g = 0x22, .b = 0x33 } },
        },
        .{
            .name = "rgb24",
            .a = .{ .rgb24 = .{ .value = .{ 0xAA, 0xBB, 0xCC } } },
            .b = .{ .rgb24 = .{ .value = .{ 0x11, 0x22, 0x33 } } },
            .other = .{ .argb = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC, .a = 0xDD } },
        },
        .{
            .name = "bgr24",
            .a = .{ .bgr24 = .{ .value = .{ 0xCC, 0xAA, 0xBB } } },
            .b = .{ .bgr24 = .{ .value = .{ 0x33, 0x11, 0x22 } } },
            .other = .{ .argb = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC, .a = 0xDD } },
        },
        .{
            .name = "rgb565",
            .a = .{ .rgb565 = .{ .r = 28, .g = 56, .b = 21 } },
            .b = .{ .rgb565 = .{ .r = 21, .g = 46, .b = 28 } },
            .other = .{ .xrgb = .{ .r = 0x11, .g = 0x22, .b = 0x33 } },
        },
        .{
            .name = "alpha8",
            .a = .{ .alpha8 = .{ .a = 0xDD } },
            .b = .{ .alpha8 = .{ .a = 0x44 } },
            .other = .{ .xrgb = .{ .r = 0x11, .g = 0x22, .b = 0x33 } },
        },
        .{
            .name = "alpha4",
            .a = .{ .alpha8 = .{ .a = 0xD } },
            .b = .{ .alpha8 = .{ .a = 0x4 } },
            .other = .{ .xrgb = .{ .r = 0x11, .g = 0x22, .b = 0x33 } },
        },
        .{
            .name = "alpha2",
            .a = .{ .alpha8 = .{ .a = 3 } },
            .b = .{ .alpha8 = .{ .a = 2 } },
            .other = .{ .xrgb = .{ .r = 0x11, .g = 0x22, .b = 0x33 } },
        },
        .{
            .name = "alpha1",
            .a = .{ .alpha8 = .{ .a = 1 } },
            .b = .{ .alpha8 = .{ .a = 0 } },
            .other = .{ .xrgb = .{ .r = 0x11, .g = 0x22, .b = 0x33 } },
        },
    };
    const TestFn = struct {
        fn f(tc: anytype) TestingError!void {
            try std.testing.expect(tc.a.equal(tc.a));
            try std.testing.expect(!tc.a.equal(tc.b));
            try std.testing.expect(!tc.a.equal(tc.other));
        }
    };
    try runCases(name, cases, TestFn.f);
}

test "Pixel endianness" {
    // Note that this can be a bit tricky to visualize (at least for me),
    // because some endianness diagrams (read: the one on Wikipedia, heh) will
    // use an integer of { 0x0A, 0x0B, 0x0C, 0x0D } (so 0A0B0C0D) and map it,
    // and you would get confused because in this case the most-significant
    // byte is 0xD, not 0xA.
    //
    // So rather, visualize it in terms of ARGB, working off of Zig's packed
    // struct layout being little-endian oriented:
    //
    //   3 2 1 0
    //   --------
    //   A R G B -> 0 | B
    //   | | +----> 1 | G
    //   | +------> 2 | R
    //   +--------> 3 | A
    //
    // This also means that when things like Wayland describe their formats as
    // like "ARGB, little endian" you have to take the layout in terms of the
    // integer, and not necessarily to how it looks in memory, i.e., "ARGB"
    // describes the whole integer in the sense that the blue channel is the
    // least significant byte.

    {
        const name = "Endianness for 32-bit pixels";
        const cases = [_]struct {
            name: []const u8,
            px: Pixel,
            expected: [4]u8,
        }{
            .{
                .name = "argb",
                .px = .{ .argb = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC, .a = 0xDD } },
                .expected = .{ 0xCC, 0xBB, 0xAA, 0xDD },
            },
            .{
                .name = "xrgb",
                .px = .{ .xrgb = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC } },
                .expected = .{ 0xCC, 0xBB, 0xAA, 0x00 },
            },
            .{
                .name = "rgb",
                .px = .{ .rgb = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC } },
                .expected = .{ 0xAA, 0xBB, 0xCC, 0x00 },
            },
            .{
                .name = "rgba",
                .px = .{ .rgba = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC, .a = 0xDD } },
                .expected = .{ 0xAA, 0xBB, 0xCC, 0xDD },
            },
        };
        const TestFn = struct {
            fn f(tc: anytype) TestingError!void {
                const got: [4]u8 = switch (tc.px) {
                    inline .argb, .xrgb, .rgb, .rgba => |p| @bitCast(p),
                    else => unreachable,
                };
                try std.testing.expectEqualSlices(u8, &tc.expected, &@as([4]u8, got));
            }
        };
        try runCases(name, cases, TestFn.f);
    }
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
            try std.testing.expectEqualDeep(tc.expected, Pixel.fromColor(tc.args));
        }
    };
    try runCases(name, cases, TestFn.f);
}

test "ARGB.canDemultiply" {
    const name = "ARGB.canDemultiply";
    const cases = [_]struct {
        name: []const u8,
        px: ARGB,
        expected: bool,
    }{
        .{
            .name = "good",
            .px = .{ .r = 127, .g = 127, .b = 127, .a = 128 },
            .expected = true,
        },
        .{
            .name = "good, zero alpha",
            .px = .{ .r = 180, .g = 180, .b = 180, .a = 0 }, // Deliberately bad values cuz this is fast-pathed
            .expected = true,
        },
        .{
            .name = "bad, r",
            .px = .{ .r = 180, .g = 127, .b = 127, .a = 128 },
            .expected = false,
        },
        .{
            .name = "bad, g",
            .px = .{ .r = 127, .g = 180, .b = 127, .a = 128 },
            .expected = false,
        },
        .{
            .name = "bad, b",
            .px = .{ .r = 127, .g = 127, .b = 180, .a = 128 },
            .expected = false,
        },
    };
    const TestFn = struct {
        fn f(tc: anytype) TestingError!void {
            try std.testing.expectEqual(tc.expected, tc.px.canDemultiply());
        }
    };
    try runCases(name, cases, TestFn.f);
}

test "RGBA.canDemultiply" {
    const name = "RGBA.canDemultiply";
    const cases = [_]struct {
        name: []const u8,
        px: RGBA,
        expected: bool,
    }{
        .{
            .name = "good",
            .px = .{ .r = 127, .g = 127, .b = 127, .a = 128 },
            .expected = true,
        },
        .{
            .name = "good, zero alpha",
            .px = .{ .r = 180, .g = 180, .b = 180, .a = 0 }, // Deliberately bad values cuz this is fast-pathed
            .expected = true,
        },
        .{
            .name = "bad, r",
            .px = .{ .r = 180, .g = 127, .b = 127, .a = 128 },
            .expected = false,
        },
        .{
            .name = "bad, g",
            .px = .{ .r = 127, .g = 180, .b = 127, .a = 128 },
            .expected = false,
        },
        .{
            .name = "bad, b",
            .px = .{ .r = 127, .g = 127, .b = 180, .a = 128 },
            .expected = false,
        },
    };
    const TestFn = struct {
        fn f(tc: anytype) TestingError!void {
            try std.testing.expectEqual(tc.expected, tc.px.canDemultiply());
        }
    };
    try runCases(name, cases, TestFn.f);
}

test "ArrayU8" {
    // An RGBA little endian type.
    const RGBLittle = ArrayU8("bgr");

    {
        // Init
        var rgba_px: RGBLittle = .init(.{ 1, 2, 3 });

        // Getters
        try std.testing.expectEqual(3, rgba_px.r());
        try std.testing.expectEqual(2, rgba_px.g());
        try std.testing.expectEqual(1, rgba_px.b());

        // Setters
        rgba_px.setR(30);
        rgba_px.setG(20);
        rgba_px.setB(10);
        try std.testing.expectEqual(30, rgba_px.r());
        try std.testing.expectEqual(20, rgba_px.g());
        try std.testing.expectEqual(10, rgba_px.b());
    }

    {
        // fromRGB
        const rgba_px: RGBLittle = .fromRGB(.{ .r = 10, .g = 20, .b = 30 });
        try std.testing.expectEqual(10, rgba_px.r());
        try std.testing.expectEqual(20, rgba_px.g());
        try std.testing.expectEqual(30, rgba_px.b());
    }
}
