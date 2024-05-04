// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024 Chris Marchesi

//! Pixel types represented by the library.

const math = @import("std").math;
const mem = @import("std").mem;
const testing = @import("std").testing;

/// Format descriptors for the pixel formats supported by the library:
///
/// * `.rgba` is 24-bit truecolor as an 8-bit depth RGB, *with* alpha channel.
/// * `.rgb` is 24-bit truecolor as an 8-bit depth RGB, *without* alpha channel.
/// * `.alpha8` is an 8-bit alpha channel.
pub const Format = enum {
    rgb,
    rgba,
    alpha8,
};

/// Represents an interface as a union of the pixel formats.
pub const Pixel = union(Format) {
    rgb: RGB,
    rgba: RGBA,
    alpha8: Alpha8,

    /// Returns the result of compositing the supplied pixel over this one (the
    /// Porter-Duff src-over operation).
    ///
    /// All pixel types with color channels are expected to be pre-multiplied.
    pub fn srcOver(dst: Pixel, src: Pixel) Pixel {
        return switch (dst) {
            inline else => |d| d.srcOver(src).asPixel(),
        };
    }

    /// Returns the result of compositing the supplied pixel in this one (the
    /// Porter-Duff dst-in operation).
    ///
    /// All pixel types with color channels are expected to be pre-multiplied.
    pub fn dstIn(dst: Pixel, src: Pixel) Pixel {
        return switch (dst) {
            inline else => |d| d.dstIn(src).asPixel(),
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
    pub fn fromPixel(p: Pixel) !RGB {
        return switch (p) {
            Format.rgb => |q| q,
            else => error.InvalidPixelFormat,
        };
    }

    /// Returns the pixel transformed by the Porter-Duff "src" operation. This
    /// is essentially a cast from the source pixel.
    pub fn copySrc(p: Pixel) RGB {
        return switch (p) {
            .rgb => |q| q,
            .rgba => |q| .{
                .r = q.r,
                .g = q.g,
                .b = q.b,
                .a = 255,
            },
            .alpha8 => .{
                .a = 255,
            },
        };
    }

    /// Returns a color from a CSS2 name.
    pub fn fromName(name: []const u8) ?RGB {
        if (mem.eql(u8, name, "aliceblue")) {
            return .{ .r = 240, .g = 248, .b = 255 };
        } else if (mem.eql(u8, name, "antiquewhite")) {
            return .{ .r = 250, .g = 235, .b = 215 };
        } else if (mem.eql(u8, name, "aqua")) {
            return .{ .r = 0, .g = 255, .b = 255 };
        } else if (mem.eql(u8, name, "aquamarine")) {
            return .{ .r = 127, .g = 255, .b = 212 };
        } else if (mem.eql(u8, name, "azure")) {
            return .{ .r = 240, .g = 255, .b = 255 };
        } else if (mem.eql(u8, name, "beige")) {
            return .{ .r = 245, .g = 245, .b = 220 };
        } else if (mem.eql(u8, name, "bisque")) {
            return .{ .r = 255, .g = 228, .b = 196 };
        } else if (mem.eql(u8, name, "black")) {
            return .{ .r = 0, .g = 0, .b = 0 };
        } else if (mem.eql(u8, name, "blanchedalmond")) {
            return .{ .r = 255, .g = 235, .b = 205 };
        } else if (mem.eql(u8, name, "blue")) {
            return .{ .r = 0, .g = 0, .b = 255 };
        } else if (mem.eql(u8, name, "blueviolet")) {
            return .{ .r = 138, .g = 43, .b = 226 };
        } else if (mem.eql(u8, name, "brown")) {
            return .{ .r = 165, .g = 42, .b = 42 };
        } else if (mem.eql(u8, name, "burlywood")) {
            return .{ .r = 222, .g = 184, .b = 135 };
        } else if (mem.eql(u8, name, "cadetblue")) {
            return .{ .r = 95, .g = 158, .b = 160 };
        } else if (mem.eql(u8, name, "chartreuse")) {
            return .{ .r = 127, .g = 255, .b = 0 };
        } else if (mem.eql(u8, name, "chocolate")) {
            return .{ .r = 210, .g = 105, .b = 30 };
        } else if (mem.eql(u8, name, "coral")) {
            return .{ .r = 255, .g = 127, .b = 80 };
        } else if (mem.eql(u8, name, "cornflowerblue")) {
            return .{ .r = 100, .g = 149, .b = 237 };
        } else if (mem.eql(u8, name, "cornsilk")) {
            return .{ .r = 255, .g = 248, .b = 220 };
        } else if (mem.eql(u8, name, "crimson")) {
            return .{ .r = 220, .g = 20, .b = 60 };
        } else if (mem.eql(u8, name, "cyan")) {
            return .{ .r = 0, .g = 255, .b = 255 };
        } else if (mem.eql(u8, name, "darkblue")) {
            return .{ .r = 0, .g = 0, .b = 139 };
        } else if (mem.eql(u8, name, "darkcyan")) {
            return .{ .r = 0, .g = 139, .b = 139 };
        } else if (mem.eql(u8, name, "darkgoldenrod")) {
            return .{ .r = 184, .g = 134, .b = 11 };
        } else if (mem.eql(u8, name, "darkgray")) {
            return .{ .r = 169, .g = 169, .b = 169 };
        } else if (mem.eql(u8, name, "darkgreen")) {
            return .{ .r = 0, .g = 100, .b = 0 };
        } else if (mem.eql(u8, name, "darkgrey")) {
            return .{ .r = 169, .g = 169, .b = 169 };
        } else if (mem.eql(u8, name, "darkkhaki")) {
            return .{ .r = 189, .g = 183, .b = 107 };
        } else if (mem.eql(u8, name, "darkmagenta")) {
            return .{ .r = 139, .g = 0, .b = 139 };
        } else if (mem.eql(u8, name, "darkolivegreen")) {
            return .{ .r = 85, .g = 107, .b = 47 };
        } else if (mem.eql(u8, name, "darkorange")) {
            return .{ .r = 255, .g = 140, .b = 0 };
        } else if (mem.eql(u8, name, "darkorchid")) {
            return .{ .r = 153, .g = 50, .b = 204 };
        } else if (mem.eql(u8, name, "darkred")) {
            return .{ .r = 139, .g = 0, .b = 0 };
        } else if (mem.eql(u8, name, "darksalmon")) {
            return .{ .r = 233, .g = 150, .b = 122 };
        } else if (mem.eql(u8, name, "darkseagreen")) {
            return .{ .r = 143, .g = 188, .b = 143 };
        } else if (mem.eql(u8, name, "darkslateblue")) {
            return .{ .r = 72, .g = 61, .b = 139 };
        } else if (mem.eql(u8, name, "darkslategray")) {
            return .{ .r = 47, .g = 79, .b = 79 };
        } else if (mem.eql(u8, name, "darkslategrey")) {
            return .{ .r = 47, .g = 79, .b = 79 };
        } else if (mem.eql(u8, name, "darkturquoise")) {
            return .{ .r = 0, .g = 206, .b = 209 };
        } else if (mem.eql(u8, name, "darkviolet")) {
            return .{ .r = 148, .g = 0, .b = 211 };
        } else if (mem.eql(u8, name, "deeppink")) {
            return .{ .r = 255, .g = 20, .b = 147 };
        } else if (mem.eql(u8, name, "deepskyblue")) {
            return .{ .r = 0, .g = 191, .b = 255 };
        } else if (mem.eql(u8, name, "dimgray")) {
            return .{ .r = 105, .g = 105, .b = 105 };
        } else if (mem.eql(u8, name, "dimgrey")) {
            return .{ .r = 105, .g = 105, .b = 105 };
        } else if (mem.eql(u8, name, "dodgerblue")) {
            return .{ .r = 30, .g = 144, .b = 255 };
        } else if (mem.eql(u8, name, "firebrick")) {
            return .{ .r = 178, .g = 34, .b = 34 };
        } else if (mem.eql(u8, name, "floralwhite")) {
            return .{ .r = 255, .g = 250, .b = 240 };
        } else if (mem.eql(u8, name, "forestgreen")) {
            return .{ .r = 34, .g = 139, .b = 34 };
        } else if (mem.eql(u8, name, "fuchsia")) {
            return .{ .r = 255, .g = 0, .b = 255 };
        } else if (mem.eql(u8, name, "gainsboro")) {
            return .{ .r = 220, .g = 220, .b = 220 };
        } else if (mem.eql(u8, name, "ghostwhite")) {
            return .{ .r = 248, .g = 248, .b = 255 };
        } else if (mem.eql(u8, name, "goldenrod")) {
            return .{ .r = 218, .g = 165, .b = 32 };
        } else if (mem.eql(u8, name, "gold")) {
            return .{ .r = 255, .g = 215, .b = 0 };
        } else if (mem.eql(u8, name, "gray")) {
            return .{ .r = 128, .g = 128, .b = 128 };
        } else if (mem.eql(u8, name, "green")) {
            return .{ .r = 0, .g = 128, .b = 0 };
        } else if (mem.eql(u8, name, "greenyellow")) {
            return .{ .r = 173, .g = 255, .b = 47 };
        } else if (mem.eql(u8, name, "grey")) {
            return .{ .r = 128, .g = 128, .b = 128 };
        } else if (mem.eql(u8, name, "honeydew")) {
            return .{ .r = 240, .g = 255, .b = 240 };
        } else if (mem.eql(u8, name, "hotpink")) {
            return .{ .r = 255, .g = 105, .b = 180 };
        } else if (mem.eql(u8, name, "indianred")) {
            return .{ .r = 205, .g = 92, .b = 92 };
        } else if (mem.eql(u8, name, "indigo")) {
            return .{ .r = 75, .g = 0, .b = 130 };
        } else if (mem.eql(u8, name, "ivory")) {
            return .{ .r = 255, .g = 255, .b = 240 };
        } else if (mem.eql(u8, name, "khaki")) {
            return .{ .r = 240, .g = 230, .b = 140 };
        } else if (mem.eql(u8, name, "lavenderblush")) {
            return .{ .r = 255, .g = 240, .b = 245 };
        } else if (mem.eql(u8, name, "lavender")) {
            return .{ .r = 230, .g = 230, .b = 250 };
        } else if (mem.eql(u8, name, "lawngreen")) {
            return .{ .r = 124, .g = 252, .b = 0 };
        } else if (mem.eql(u8, name, "lemonchiffon")) {
            return .{ .r = 255, .g = 250, .b = 205 };
        } else if (mem.eql(u8, name, "lightblue")) {
            return .{ .r = 173, .g = 216, .b = 230 };
        } else if (mem.eql(u8, name, "lightcoral")) {
            return .{ .r = 240, .g = 128, .b = 128 };
        } else if (mem.eql(u8, name, "lightcyan")) {
            return .{ .r = 224, .g = 255, .b = 255 };
        } else if (mem.eql(u8, name, "lightgoldenrodyellow")) {
            return .{ .r = 250, .g = 250, .b = 210 };
        } else if (mem.eql(u8, name, "lightgray")) {
            return .{ .r = 211, .g = 211, .b = 211 };
        } else if (mem.eql(u8, name, "lightgreen")) {
            return .{ .r = 144, .g = 238, .b = 144 };
        } else if (mem.eql(u8, name, "lightgrey")) {
            return .{ .r = 211, .g = 211, .b = 211 };
        } else if (mem.eql(u8, name, "lightpink")) {
            return .{ .r = 255, .g = 182, .b = 193 };
        } else if (mem.eql(u8, name, "lightsalmon")) {
            return .{ .r = 255, .g = 160, .b = 122 };
        } else if (mem.eql(u8, name, "lightseagreen")) {
            return .{ .r = 32, .g = 178, .b = 170 };
        } else if (mem.eql(u8, name, "lightskyblue")) {
            return .{ .r = 135, .g = 206, .b = 250 };
        } else if (mem.eql(u8, name, "lightslategray")) {
            return .{ .r = 119, .g = 136, .b = 153 };
        } else if (mem.eql(u8, name, "lightslategrey")) {
            return .{ .r = 119, .g = 136, .b = 153 };
        } else if (mem.eql(u8, name, "lightsteelblue")) {
            return .{ .r = 176, .g = 196, .b = 222 };
        } else if (mem.eql(u8, name, "lightyellow")) {
            return .{ .r = 255, .g = 255, .b = 224 };
        } else if (mem.eql(u8, name, "lime")) {
            return .{ .r = 0, .g = 255, .b = 0 };
        } else if (mem.eql(u8, name, "limegreen")) {
            return .{ .r = 50, .g = 205, .b = 50 };
        } else if (mem.eql(u8, name, "linen")) {
            return .{ .r = 250, .g = 240, .b = 230 };
        } else if (mem.eql(u8, name, "magenta")) {
            return .{ .r = 255, .g = 0, .b = 255 };
        } else if (mem.eql(u8, name, "maroon")) {
            return .{ .r = 128, .g = 0, .b = 0 };
        } else if (mem.eql(u8, name, "mediumaquamarine")) {
            return .{ .r = 102, .g = 205, .b = 170 };
        } else if (mem.eql(u8, name, "mediumblue")) {
            return .{ .r = 0, .g = 0, .b = 205 };
        } else if (mem.eql(u8, name, "mediumorchid")) {
            return .{ .r = 186, .g = 85, .b = 211 };
        } else if (mem.eql(u8, name, "mediumpurple")) {
            return .{ .r = 147, .g = 112, .b = 219 };
        } else if (mem.eql(u8, name, "mediumseagreen")) {
            return .{ .r = 60, .g = 179, .b = 113 };
        } else if (mem.eql(u8, name, "mediumslateblue")) {
            return .{ .r = 123, .g = 104, .b = 238 };
        } else if (mem.eql(u8, name, "mediumspringgreen")) {
            return .{ .r = 0, .g = 250, .b = 154 };
        } else if (mem.eql(u8, name, "mediumturquoise")) {
            return .{ .r = 72, .g = 209, .b = 204 };
        } else if (mem.eql(u8, name, "mediumvioletred")) {
            return .{ .r = 199, .g = 21, .b = 133 };
        } else if (mem.eql(u8, name, "midnightblue")) {
            return .{ .r = 25, .g = 25, .b = 112 };
        } else if (mem.eql(u8, name, "mintcream")) {
            return .{ .r = 245, .g = 255, .b = 250 };
        } else if (mem.eql(u8, name, "mistyrose")) {
            return .{ .r = 255, .g = 228, .b = 225 };
        } else if (mem.eql(u8, name, "moccasin")) {
            return .{ .r = 255, .g = 228, .b = 181 };
        } else if (mem.eql(u8, name, "navajowhite")) {
            return .{ .r = 255, .g = 222, .b = 173 };
        } else if (mem.eql(u8, name, "navy")) {
            return .{ .r = 0, .g = 0, .b = 128 };
        } else if (mem.eql(u8, name, "oldlace")) {
            return .{ .r = 253, .g = 245, .b = 230 };
        } else if (mem.eql(u8, name, "olive")) {
            return .{ .r = 128, .g = 128, .b = 0 };
        } else if (mem.eql(u8, name, "olivedrab")) {
            return .{ .r = 107, .g = 142, .b = 35 };
        } else if (mem.eql(u8, name, "orange")) {
            return .{ .r = 255, .g = 165, .b = 0 };
        } else if (mem.eql(u8, name, "orangered")) {
            return .{ .r = 255, .g = 69, .b = 0 };
        } else if (mem.eql(u8, name, "orchid")) {
            return .{ .r = 218, .g = 112, .b = 214 };
        } else if (mem.eql(u8, name, "palegoldenrod")) {
            return .{ .r = 238, .g = 232, .b = 170 };
        } else if (mem.eql(u8, name, "palegreen")) {
            return .{ .r = 152, .g = 251, .b = 152 };
        } else if (mem.eql(u8, name, "paleturquoise")) {
            return .{ .r = 175, .g = 238, .b = 238 };
        } else if (mem.eql(u8, name, "palevioletred")) {
            return .{ .r = 219, .g = 112, .b = 147 };
        } else if (mem.eql(u8, name, "papayawhip")) {
            return .{ .r = 255, .g = 239, .b = 213 };
        } else if (mem.eql(u8, name, "peachpuff")) {
            return .{ .r = 255, .g = 218, .b = 185 };
        } else if (mem.eql(u8, name, "peru")) {
            return .{ .r = 205, .g = 133, .b = 63 };
        } else if (mem.eql(u8, name, "pink")) {
            return .{ .r = 255, .g = 192, .b = 203 };
        } else if (mem.eql(u8, name, "plum")) {
            return .{ .r = 221, .g = 160, .b = 221 };
        } else if (mem.eql(u8, name, "powderblue")) {
            return .{ .r = 176, .g = 224, .b = 230 };
        } else if (mem.eql(u8, name, "purple")) {
            return .{ .r = 128, .g = 0, .b = 128 };
        } else if (mem.eql(u8, name, "red")) {
            return .{ .r = 255, .g = 0, .b = 0 };
        } else if (mem.eql(u8, name, "rosybrown")) {
            return .{ .r = 188, .g = 143, .b = 143 };
        } else if (mem.eql(u8, name, "royalblue")) {
            return .{ .r = 65, .g = 105, .b = 225 };
        } else if (mem.eql(u8, name, "saddlebrown")) {
            return .{ .r = 139, .g = 69, .b = 19 };
        } else if (mem.eql(u8, name, "salmon")) {
            return .{ .r = 250, .g = 128, .b = 114 };
        } else if (mem.eql(u8, name, "sandybrown")) {
            return .{ .r = 244, .g = 164, .b = 96 };
        } else if (mem.eql(u8, name, "seagreen")) {
            return .{ .r = 46, .g = 139, .b = 87 };
        } else if (mem.eql(u8, name, "seashell")) {
            return .{ .r = 255, .g = 245, .b = 238 };
        } else if (mem.eql(u8, name, "sienna")) {
            return .{ .r = 160, .g = 82, .b = 45 };
        } else if (mem.eql(u8, name, "silver")) {
            return .{ .r = 192, .g = 192, .b = 192 };
        } else if (mem.eql(u8, name, "skyblue")) {
            return .{ .r = 135, .g = 206, .b = 235 };
        } else if (mem.eql(u8, name, "slateblue")) {
            return .{ .r = 106, .g = 90, .b = 205 };
        } else if (mem.eql(u8, name, "slategray")) {
            return .{ .r = 112, .g = 128, .b = 144 };
        } else if (mem.eql(u8, name, "slategrey")) {
            return .{ .r = 112, .g = 128, .b = 144 };
        } else if (mem.eql(u8, name, "snow")) {
            return .{ .r = 255, .g = 250, .b = 250 };
        } else if (mem.eql(u8, name, "springgreen")) {
            return .{ .r = 0, .g = 255, .b = 127 };
        } else if (mem.eql(u8, name, "steelblue")) {
            return .{ .r = 70, .g = 130, .b = 180 };
        } else if (mem.eql(u8, name, "tan")) {
            return .{ .r = 210, .g = 180, .b = 140 };
        } else if (mem.eql(u8, name, "teal")) {
            return .{ .r = 0, .g = 128, .b = 128 };
        } else if (mem.eql(u8, name, "thistle")) {
            return .{ .r = 216, .g = 191, .b = 216 };
        } else if (mem.eql(u8, name, "tomato")) {
            return .{ .r = 255, .g = 99, .b = 71 };
        } else if (mem.eql(u8, name, "turquoise")) {
            return .{ .r = 64, .g = 224, .b = 208 };
        } else if (mem.eql(u8, name, "violet")) {
            return .{ .r = 238, .g = 130, .b = 238 };
        } else if (mem.eql(u8, name, "wheat")) {
            return .{ .r = 245, .g = 222, .b = 179 };
        } else if (mem.eql(u8, name, "white")) {
            return .{ .r = 255, .g = 255, .b = 255 };
        } else if (mem.eql(u8, name, "whitesmoke")) {
            return .{ .r = 245, .g = 245, .b = 245 };
        } else if (mem.eql(u8, name, "yellow")) {
            return .{ .r = 255, .g = 255, .b = 0 };
        } else if (mem.eql(u8, name, "yellowgreen")) {
            return .{ .r = 154, .g = 205, .b = 50 };
        }

        return null;
    }

    /// Returns an average of the pixels in the supplied slice.
    ///
    /// The average of a zero-length slice is pure black.
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

    /// Returns the result of compositing the supplied pixel over this one (the
    /// Porter-Duff src-over operation).
    ///
    /// All pixel types with color channels are expected to be pre-multiplied.
    pub fn srcOver(dst: RGB, src: Pixel) RGB {
        const d = .{
            .r = @as(u32, @intCast(dst.r)),
            .g = @as(u32, @intCast(dst.g)),
            .b = @as(u32, @intCast(dst.b)),
        };
        return switch (src) {
            .rgb => |s| .{
                .r = s.r,
                .g = s.g,
                .b = s.b,
            },
            .rgba => |s| .{
                .r = @intCast(s.r + (255 * d.r - d.r * s.a) / 255),
                .g = @intCast(s.g + (255 * d.g - d.g * s.a) / 255),
                .b = @intCast(s.b + (255 * d.b - d.b * s.a) / 255),
            },
            .alpha8 => |s| .{
                .r = @intCast((255 * d.r - d.r * s.a) / 255),
                .g = @intCast((255 * d.g - d.g * s.a) / 255),
                .b = @intCast((255 * d.b - d.b * s.a) / 255),
            },
        };
    }

    /// Returns the result of compositing the supplied pixel in this one (the
    /// Porter-Duff dst-in operation).
    ///
    /// All pixel types with color channels are expected to be pre-multiplied.
    pub fn dstIn(dst: RGB, src: Pixel) RGB {
        const d = .{
            .r = @as(u32, @intCast(dst.r)),
            .g = @as(u32, @intCast(dst.g)),
            .b = @as(u32, @intCast(dst.b)),
        };
        return switch (src) {
            // Special case for RGB: just return the destination pixel (we
            // assume that every RGB pixel has full opacity).
            .rgb => .{
                .r = dst.r,
                .g = dst.g,
                .b = dst.b,
            },
            .rgba => |s| .{
                .r = @intCast(d.r * s.a / 255),
                .g = @intCast(d.g * s.a / 255),
                .b = @intCast(d.b * s.a / 255),
            },
            .alpha8 => |s| .{
                .r = @intCast(d.r * s.a / 255),
                .g = @intCast(d.g * s.a / 255),
                .b = @intCast(d.b * s.a / 255),
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

    /// Returns a pixel from a clamped 0-1 value.
    ///
    /// The helper expects the values as straight alpha and will pre-multiply
    /// the values for you.
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
    pub fn fromPixel(p: Pixel) !RGBA {
        return switch (p) {
            Format.rgba => |q| q,
            else => error.InvalidPixelFormat,
        };
    }

    /// Returns the pixel transformed by the Porter-Duff "src" operation. This
    /// is essentially a cast from the source pixel.
    pub fn copySrc(p: Pixel) RGBA {
        return switch (p) {
            .rgb => |q| .{
                .r = q.r,
                .g = q.g,
                .b = q.b,
                .a = 255,
            },
            .rgba => |q| q,
            .alpha8 => .{
                .r = 0,
                .g = 0,
                .b = 0,
                .a = 255,
            },
        };
    }

    /// Returns a color from a CSS2 name.
    pub fn fromName(name: []const u8) ?RGBA {
        if (mem.eql(u8, name, "aliceblue")) {
            return .{ .r = 240, .g = 248, .b = 255, .a = 255 };
        } else if (mem.eql(u8, name, "antiquewhite")) {
            return .{ .r = 250, .g = 235, .b = 215, .a = 255 };
        } else if (mem.eql(u8, name, "aqua")) {
            return .{ .r = 0, .g = 255, .b = 255, .a = 255 };
        } else if (mem.eql(u8, name, "aquamarine")) {
            return .{ .r = 127, .g = 255, .b = 212, .a = 255 };
        } else if (mem.eql(u8, name, "azure")) {
            return .{ .r = 240, .g = 255, .b = 255, .a = 255 };
        } else if (mem.eql(u8, name, "beige")) {
            return .{ .r = 245, .g = 245, .b = 220, .a = 255 };
        } else if (mem.eql(u8, name, "bisque")) {
            return .{ .r = 255, .g = 228, .b = 196, .a = 255 };
        } else if (mem.eql(u8, name, "black")) {
            return .{ .r = 0, .g = 0, .b = 0, .a = 255 };
        } else if (mem.eql(u8, name, "blanchedalmond")) {
            return .{ .r = 255, .g = 235, .b = 205, .a = 255 };
        } else if (mem.eql(u8, name, "blue")) {
            return .{ .r = 0, .g = 0, .b = 255, .a = 255 };
        } else if (mem.eql(u8, name, "blueviolet")) {
            return .{ .r = 138, .g = 43, .b = 226, .a = 255 };
        } else if (mem.eql(u8, name, "brown")) {
            return .{ .r = 165, .g = 42, .b = 42, .a = 255 };
        } else if (mem.eql(u8, name, "burlywood")) {
            return .{ .r = 222, .g = 184, .b = 135, .a = 255 };
        } else if (mem.eql(u8, name, "cadetblue")) {
            return .{ .r = 95, .g = 158, .b = 160, .a = 255 };
        } else if (mem.eql(u8, name, "chartreuse")) {
            return .{ .r = 127, .g = 255, .b = 0, .a = 255 };
        } else if (mem.eql(u8, name, "chocolate")) {
            return .{ .r = 210, .g = 105, .b = 30, .a = 255 };
        } else if (mem.eql(u8, name, "coral")) {
            return .{ .r = 255, .g = 127, .b = 80, .a = 255 };
        } else if (mem.eql(u8, name, "cornflowerblue")) {
            return .{ .r = 100, .g = 149, .b = 237, .a = 255 };
        } else if (mem.eql(u8, name, "cornsilk")) {
            return .{ .r = 255, .g = 248, .b = 220, .a = 255 };
        } else if (mem.eql(u8, name, "crimson")) {
            return .{ .r = 220, .g = 20, .b = 60, .a = 255 };
        } else if (mem.eql(u8, name, "cyan")) {
            return .{ .r = 0, .g = 255, .b = 255, .a = 255 };
        } else if (mem.eql(u8, name, "darkblue")) {
            return .{ .r = 0, .g = 0, .b = 139, .a = 255 };
        } else if (mem.eql(u8, name, "darkcyan")) {
            return .{ .r = 0, .g = 139, .b = 139, .a = 255 };
        } else if (mem.eql(u8, name, "darkgoldenrod")) {
            return .{ .r = 184, .g = 134, .b = 11, .a = 255 };
        } else if (mem.eql(u8, name, "darkgray")) {
            return .{ .r = 169, .g = 169, .b = 169, .a = 255 };
        } else if (mem.eql(u8, name, "darkgreen")) {
            return .{ .r = 0, .g = 100, .b = 0, .a = 255 };
        } else if (mem.eql(u8, name, "darkgrey")) {
            return .{ .r = 169, .g = 169, .b = 169, .a = 255 };
        } else if (mem.eql(u8, name, "darkkhaki")) {
            return .{ .r = 189, .g = 183, .b = 107, .a = 255 };
        } else if (mem.eql(u8, name, "darkmagenta")) {
            return .{ .r = 139, .g = 0, .b = 139, .a = 255 };
        } else if (mem.eql(u8, name, "darkolivegreen")) {
            return .{ .r = 85, .g = 107, .b = 47, .a = 255 };
        } else if (mem.eql(u8, name, "darkorange")) {
            return .{ .r = 255, .g = 140, .b = 0, .a = 255 };
        } else if (mem.eql(u8, name, "darkorchid")) {
            return .{ .r = 153, .g = 50, .b = 204, .a = 255 };
        } else if (mem.eql(u8, name, "darkred")) {
            return .{ .r = 139, .g = 0, .b = 0, .a = 255 };
        } else if (mem.eql(u8, name, "darksalmon")) {
            return .{ .r = 233, .g = 150, .b = 122, .a = 255 };
        } else if (mem.eql(u8, name, "darkseagreen")) {
            return .{ .r = 143, .g = 188, .b = 143, .a = 255 };
        } else if (mem.eql(u8, name, "darkslateblue")) {
            return .{ .r = 72, .g = 61, .b = 139, .a = 255 };
        } else if (mem.eql(u8, name, "darkslategray")) {
            return .{ .r = 47, .g = 79, .b = 79, .a = 255 };
        } else if (mem.eql(u8, name, "darkslategrey")) {
            return .{ .r = 47, .g = 79, .b = 79, .a = 255 };
        } else if (mem.eql(u8, name, "darkturquoise")) {
            return .{ .r = 0, .g = 206, .b = 209, .a = 255 };
        } else if (mem.eql(u8, name, "darkviolet")) {
            return .{ .r = 148, .g = 0, .b = 211, .a = 255 };
        } else if (mem.eql(u8, name, "deeppink")) {
            return .{ .r = 255, .g = 20, .b = 147, .a = 255 };
        } else if (mem.eql(u8, name, "deepskyblue")) {
            return .{ .r = 0, .g = 191, .b = 255, .a = 255 };
        } else if (mem.eql(u8, name, "dimgray")) {
            return .{ .r = 105, .g = 105, .b = 105, .a = 255 };
        } else if (mem.eql(u8, name, "dimgrey")) {
            return .{ .r = 105, .g = 105, .b = 105, .a = 255 };
        } else if (mem.eql(u8, name, "dodgerblue")) {
            return .{ .r = 30, .g = 144, .b = 255, .a = 255 };
        } else if (mem.eql(u8, name, "firebrick")) {
            return .{ .r = 178, .g = 34, .b = 34, .a = 255 };
        } else if (mem.eql(u8, name, "floralwhite")) {
            return .{ .r = 255, .g = 250, .b = 240, .a = 255 };
        } else if (mem.eql(u8, name, "forestgreen")) {
            return .{ .r = 34, .g = 139, .b = 34, .a = 255 };
        } else if (mem.eql(u8, name, "fuchsia")) {
            return .{ .r = 255, .g = 0, .b = 255, .a = 255 };
        } else if (mem.eql(u8, name, "gainsboro")) {
            return .{ .r = 220, .g = 220, .b = 220, .a = 255 };
        } else if (mem.eql(u8, name, "ghostwhite")) {
            return .{ .r = 248, .g = 248, .b = 255, .a = 255 };
        } else if (mem.eql(u8, name, "goldenrod")) {
            return .{ .r = 218, .g = 165, .b = 32, .a = 255 };
        } else if (mem.eql(u8, name, "gold")) {
            return .{ .r = 255, .g = 215, .b = 0, .a = 255 };
        } else if (mem.eql(u8, name, "gray")) {
            return .{ .r = 128, .g = 128, .b = 128, .a = 255 };
        } else if (mem.eql(u8, name, "green")) {
            return .{ .r = 0, .g = 128, .b = 0, .a = 255 };
        } else if (mem.eql(u8, name, "greenyellow")) {
            return .{ .r = 173, .g = 255, .b = 47, .a = 255 };
        } else if (mem.eql(u8, name, "grey")) {
            return .{ .r = 128, .g = 128, .b = 128, .a = 255 };
        } else if (mem.eql(u8, name, "honeydew")) {
            return .{ .r = 240, .g = 255, .b = 240, .a = 255 };
        } else if (mem.eql(u8, name, "hotpink")) {
            return .{ .r = 255, .g = 105, .b = 180, .a = 255 };
        } else if (mem.eql(u8, name, "indianred")) {
            return .{ .r = 205, .g = 92, .b = 92, .a = 255 };
        } else if (mem.eql(u8, name, "indigo")) {
            return .{ .r = 75, .g = 0, .b = 130, .a = 255 };
        } else if (mem.eql(u8, name, "ivory")) {
            return .{ .r = 255, .g = 255, .b = 240, .a = 255 };
        } else if (mem.eql(u8, name, "khaki")) {
            return .{ .r = 240, .g = 230, .b = 140, .a = 255 };
        } else if (mem.eql(u8, name, "lavenderblush")) {
            return .{ .r = 255, .g = 240, .b = 245, .a = 255 };
        } else if (mem.eql(u8, name, "lavender")) {
            return .{ .r = 230, .g = 230, .b = 250, .a = 255 };
        } else if (mem.eql(u8, name, "lawngreen")) {
            return .{ .r = 124, .g = 252, .b = 0, .a = 255 };
        } else if (mem.eql(u8, name, "lemonchiffon")) {
            return .{ .r = 255, .g = 250, .b = 205, .a = 255 };
        } else if (mem.eql(u8, name, "lightblue")) {
            return .{ .r = 173, .g = 216, .b = 230, .a = 255 };
        } else if (mem.eql(u8, name, "lightcoral")) {
            return .{ .r = 240, .g = 128, .b = 128, .a = 255 };
        } else if (mem.eql(u8, name, "lightcyan")) {
            return .{ .r = 224, .g = 255, .b = 255, .a = 255 };
        } else if (mem.eql(u8, name, "lightgoldenrodyellow")) {
            return .{ .r = 250, .g = 250, .b = 210, .a = 255 };
        } else if (mem.eql(u8, name, "lightgray")) {
            return .{ .r = 211, .g = 211, .b = 211, .a = 255 };
        } else if (mem.eql(u8, name, "lightgreen")) {
            return .{ .r = 144, .g = 238, .b = 144, .a = 255 };
        } else if (mem.eql(u8, name, "lightgrey")) {
            return .{ .r = 211, .g = 211, .b = 211, .a = 255 };
        } else if (mem.eql(u8, name, "lightpink")) {
            return .{ .r = 255, .g = 182, .b = 193, .a = 255 };
        } else if (mem.eql(u8, name, "lightsalmon")) {
            return .{ .r = 255, .g = 160, .b = 122, .a = 255 };
        } else if (mem.eql(u8, name, "lightseagreen")) {
            return .{ .r = 32, .g = 178, .b = 170, .a = 255 };
        } else if (mem.eql(u8, name, "lightskyblue")) {
            return .{ .r = 135, .g = 206, .b = 250, .a = 255 };
        } else if (mem.eql(u8, name, "lightslategray")) {
            return .{ .r = 119, .g = 136, .b = 153, .a = 255 };
        } else if (mem.eql(u8, name, "lightslategrey")) {
            return .{ .r = 119, .g = 136, .b = 153, .a = 255 };
        } else if (mem.eql(u8, name, "lightsteelblue")) {
            return .{ .r = 176, .g = 196, .b = 222, .a = 255 };
        } else if (mem.eql(u8, name, "lightyellow")) {
            return .{ .r = 255, .g = 255, .b = 224, .a = 255 };
        } else if (mem.eql(u8, name, "lime")) {
            return .{ .r = 0, .g = 255, .b = 0, .a = 255 };
        } else if (mem.eql(u8, name, "limegreen")) {
            return .{ .r = 50, .g = 205, .b = 50, .a = 255 };
        } else if (mem.eql(u8, name, "linen")) {
            return .{ .r = 250, .g = 240, .b = 230, .a = 255 };
        } else if (mem.eql(u8, name, "magenta")) {
            return .{ .r = 255, .g = 0, .b = 255, .a = 255 };
        } else if (mem.eql(u8, name, "maroon")) {
            return .{ .r = 128, .g = 0, .b = 0, .a = 255 };
        } else if (mem.eql(u8, name, "mediumaquamarine")) {
            return .{ .r = 102, .g = 205, .b = 170, .a = 255 };
        } else if (mem.eql(u8, name, "mediumblue")) {
            return .{ .r = 0, .g = 0, .b = 205, .a = 255 };
        } else if (mem.eql(u8, name, "mediumorchid")) {
            return .{ .r = 186, .g = 85, .b = 211, .a = 255 };
        } else if (mem.eql(u8, name, "mediumpurple")) {
            return .{ .r = 147, .g = 112, .b = 219, .a = 255 };
        } else if (mem.eql(u8, name, "mediumseagreen")) {
            return .{ .r = 60, .g = 179, .b = 113, .a = 255 };
        } else if (mem.eql(u8, name, "mediumslateblue")) {
            return .{ .r = 123, .g = 104, .b = 238, .a = 255 };
        } else if (mem.eql(u8, name, "mediumspringgreen")) {
            return .{ .r = 0, .g = 250, .b = 154, .a = 255 };
        } else if (mem.eql(u8, name, "mediumturquoise")) {
            return .{ .r = 72, .g = 209, .b = 204, .a = 255 };
        } else if (mem.eql(u8, name, "mediumvioletred")) {
            return .{ .r = 199, .g = 21, .b = 133, .a = 255 };
        } else if (mem.eql(u8, name, "midnightblue")) {
            return .{ .r = 25, .g = 25, .b = 112, .a = 255 };
        } else if (mem.eql(u8, name, "mintcream")) {
            return .{ .r = 245, .g = 255, .b = 250, .a = 255 };
        } else if (mem.eql(u8, name, "mistyrose")) {
            return .{ .r = 255, .g = 228, .b = 225, .a = 255 };
        } else if (mem.eql(u8, name, "moccasin")) {
            return .{ .r = 255, .g = 228, .b = 181, .a = 255 };
        } else if (mem.eql(u8, name, "navajowhite")) {
            return .{ .r = 255, .g = 222, .b = 173, .a = 255 };
        } else if (mem.eql(u8, name, "navy")) {
            return .{ .r = 0, .g = 0, .b = 128, .a = 255 };
        } else if (mem.eql(u8, name, "oldlace")) {
            return .{ .r = 253, .g = 245, .b = 230, .a = 255 };
        } else if (mem.eql(u8, name, "olive")) {
            return .{ .r = 128, .g = 128, .b = 0, .a = 255 };
        } else if (mem.eql(u8, name, "olivedrab")) {
            return .{ .r = 107, .g = 142, .b = 35, .a = 255 };
        } else if (mem.eql(u8, name, "orange")) {
            return .{ .r = 255, .g = 165, .b = 0, .a = 255 };
        } else if (mem.eql(u8, name, "orangered")) {
            return .{ .r = 255, .g = 69, .b = 0, .a = 255 };
        } else if (mem.eql(u8, name, "orchid")) {
            return .{ .r = 218, .g = 112, .b = 214, .a = 255 };
        } else if (mem.eql(u8, name, "palegoldenrod")) {
            return .{ .r = 238, .g = 232, .b = 170, .a = 255 };
        } else if (mem.eql(u8, name, "palegreen")) {
            return .{ .r = 152, .g = 251, .b = 152, .a = 255 };
        } else if (mem.eql(u8, name, "paleturquoise")) {
            return .{ .r = 175, .g = 238, .b = 238, .a = 255 };
        } else if (mem.eql(u8, name, "palevioletred")) {
            return .{ .r = 219, .g = 112, .b = 147, .a = 255 };
        } else if (mem.eql(u8, name, "papayawhip")) {
            return .{ .r = 255, .g = 239, .b = 213, .a = 255 };
        } else if (mem.eql(u8, name, "peachpuff")) {
            return .{ .r = 255, .g = 218, .b = 185, .a = 255 };
        } else if (mem.eql(u8, name, "peru")) {
            return .{ .r = 205, .g = 133, .b = 63, .a = 255 };
        } else if (mem.eql(u8, name, "pink")) {
            return .{ .r = 255, .g = 192, .b = 203, .a = 255 };
        } else if (mem.eql(u8, name, "plum")) {
            return .{ .r = 221, .g = 160, .b = 221, .a = 255 };
        } else if (mem.eql(u8, name, "powderblue")) {
            return .{ .r = 176, .g = 224, .b = 230, .a = 255 };
        } else if (mem.eql(u8, name, "purple")) {
            return .{ .r = 128, .g = 0, .b = 128, .a = 255 };
        } else if (mem.eql(u8, name, "red")) {
            return .{ .r = 255, .g = 0, .b = 0, .a = 255 };
        } else if (mem.eql(u8, name, "rosybrown")) {
            return .{ .r = 188, .g = 143, .b = 143, .a = 255 };
        } else if (mem.eql(u8, name, "royalblue")) {
            return .{ .r = 65, .g = 105, .b = 225, .a = 255 };
        } else if (mem.eql(u8, name, "saddlebrown")) {
            return .{ .r = 139, .g = 69, .b = 19, .a = 255 };
        } else if (mem.eql(u8, name, "salmon")) {
            return .{ .r = 250, .g = 128, .b = 114, .a = 255 };
        } else if (mem.eql(u8, name, "sandybrown")) {
            return .{ .r = 244, .g = 164, .b = 96, .a = 255 };
        } else if (mem.eql(u8, name, "seagreen")) {
            return .{ .r = 46, .g = 139, .b = 87, .a = 255 };
        } else if (mem.eql(u8, name, "seashell")) {
            return .{ .r = 255, .g = 245, .b = 238, .a = 255 };
        } else if (mem.eql(u8, name, "sienna")) {
            return .{ .r = 160, .g = 82, .b = 45, .a = 255 };
        } else if (mem.eql(u8, name, "silver")) {
            return .{ .r = 192, .g = 192, .b = 192, .a = 255 };
        } else if (mem.eql(u8, name, "skyblue")) {
            return .{ .r = 135, .g = 206, .b = 235, .a = 255 };
        } else if (mem.eql(u8, name, "slateblue")) {
            return .{ .r = 106, .g = 90, .b = 205, .a = 255 };
        } else if (mem.eql(u8, name, "slategray")) {
            return .{ .r = 112, .g = 128, .b = 144, .a = 255 };
        } else if (mem.eql(u8, name, "slategrey")) {
            return .{ .r = 112, .g = 128, .b = 144, .a = 255 };
        } else if (mem.eql(u8, name, "snow")) {
            return .{ .r = 255, .g = 250, .b = 250, .a = 255 };
        } else if (mem.eql(u8, name, "springgreen")) {
            return .{ .r = 0, .g = 255, .b = 127, .a = 255 };
        } else if (mem.eql(u8, name, "steelblue")) {
            return .{ .r = 70, .g = 130, .b = 180, .a = 255 };
        } else if (mem.eql(u8, name, "tan")) {
            return .{ .r = 210, .g = 180, .b = 140, .a = 255 };
        } else if (mem.eql(u8, name, "teal")) {
            return .{ .r = 0, .g = 128, .b = 128, .a = 255 };
        } else if (mem.eql(u8, name, "thistle")) {
            return .{ .r = 216, .g = 191, .b = 216, .a = 255 };
        } else if (mem.eql(u8, name, "tomato")) {
            return .{ .r = 255, .g = 99, .b = 71, .a = 255 };
        } else if (mem.eql(u8, name, "turquoise")) {
            return .{ .r = 64, .g = 224, .b = 208, .a = 255 };
        } else if (mem.eql(u8, name, "violet")) {
            return .{ .r = 238, .g = 130, .b = 238, .a = 255 };
        } else if (mem.eql(u8, name, "wheat")) {
            return .{ .r = 245, .g = 222, .b = 179, .a = 255 };
        } else if (mem.eql(u8, name, "white")) {
            return .{ .r = 255, .g = 255, .b = 255, .a = 255 };
        } else if (mem.eql(u8, name, "whitesmoke")) {
            return .{ .r = 245, .g = 245, .b = 245, .a = 255 };
        } else if (mem.eql(u8, name, "yellow")) {
            return .{ .r = 255, .g = 255, .b = 0, .a = 255 };
        } else if (mem.eql(u8, name, "yellowgreen")) {
            return .{ .r = 154, .g = 205, .b = 50, .a = 255 };
        }

        return null;
    }

    /// Returns an average of the pixels in the supplied slice.
    ///
    /// The average of a zero-length slice is transparent black.
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
    /// Porter-Duff src-over operation).
    ///
    /// All pixel types with color channels are expected to be pre-multiplied.
    pub fn srcOver(dst: RGBA, src: Pixel) RGBA {
        const d = .{
            .r = @as(u32, @intCast(dst.r)),
            .g = @as(u32, @intCast(dst.g)),
            .b = @as(u32, @intCast(dst.b)),
            .a = @as(u32, @intCast(dst.a)),
        };
        return switch (src) {
            .rgb => |s| .{
                .r = s.r,
                .g = s.g,
                .b = s.b,
                .a = 255,
            },
            .rgba => |s| .{
                .r = @intCast(s.r + (255 * d.r - d.r * s.a) / 255),
                .g = @intCast(s.g + (255 * d.g - d.g * s.a) / 255),
                .b = @intCast(s.b + (255 * d.b - d.b * s.a) / 255),
                .a = @intCast(s.a + d.a - s.a * d.a / 255),
            },
            .alpha8 => |s| .{
                .r = @intCast((255 * d.r - d.r * s.a) / 255),
                .g = @intCast((255 * d.g - d.g * s.a) / 255),
                .b = @intCast((255 * d.b - d.b * s.a) / 255),
                .a = @intCast(s.a + d.a - s.a * d.a / 255),
            },
        };
    }

    /// Returns the result of compositing the supplied pixel in this one (the
    /// Porter-Duff dst-in operation).
    ///
    /// All pixel types with color channels are expected to be pre-multiplied.
    pub fn dstIn(dst: RGBA, src: Pixel) RGBA {
        const d = .{
            .r = @as(u32, @intCast(dst.r)),
            .g = @as(u32, @intCast(dst.g)),
            .b = @as(u32, @intCast(dst.b)),
            .a = @as(u32, @intCast(dst.a)),
        };
        return switch (src) {
            .rgb => .{
                .r = dst.r,
                .g = dst.g,
                .b = dst.b,
                .a = dst.a,
            },
            .rgba => |s| .{
                .r = @intCast(d.r * s.a / 255),
                .g = @intCast(d.g * s.a / 255),
                .b = @intCast(d.b * s.a / 255),
                .a = @intCast(d.a * s.a / 255),
            },
            .alpha8 => |s| .{
                .r = @intCast(d.r * s.a / 255),
                .g = @intCast(d.g * s.a / 255),
                .b = @intCast(d.b * s.a / 255),
                .a = @intCast(d.a * s.a / 255),
            },
        };
    }
};

/// Describes an 8-bit alpha-channel only pixel format.
pub const Alpha8 = packed struct(u8) {
    a: u8,

    /// The format descriptor for this pixel format.
    pub const format: Format = .alpha8;

    /// Returns this pixel as an interface.
    pub fn fromPixel(p: Pixel) !Alpha8 {
        return switch (p) {
            Format.alpha8 => |q| q,
            else => error.InvalidPixelFormat,
        };
    }

    /// Returns the pixel transformed by the Porter-Duff "src" operation. This
    /// is essentially a cast from the source pixel.
    pub fn copySrc(p: Pixel) Alpha8 {
        return switch (p) {
            .rgb => .{
                .a = 255,
            },
            .rgba => |q| .{
                .a = q.a,
            },
            .alpha8 => |q| q,
        };
    }

    /// Returns an average of the pixels in the supplied slice.
    ///
    /// The average of a zero-length slice is transparent black.
    pub fn average(ps: []const Alpha8) Alpha8 {
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
    pub fn asPixel(self: Alpha8) Pixel {
        return .{ .alpha8 = self };
    }

    /// Returns the result of compositing the supplied pixel over this one (the
    /// Porter-Duff src-over operation).
    ///
    /// All pixel types with color channels are expected to be pre-multiplied.
    pub fn srcOver(dst: Alpha8, src: Pixel) Alpha8 {
        const d = .{
            .a = @as(u32, @intCast(dst.a)),
        };
        return switch (src) {
            .rgb => .{
                .a = 255,
            },
            .rgba => |s| .{
                .a = @intCast(s.a + d.a - s.a * d.a / 255),
            },
            .alpha8 => |s| .{
                .a = @intCast(s.a + d.a - s.a * d.a / 255),
            },
        };
    }

    /// Returns the result of compositing the supplied pixel in this one (the
    /// Porter-Duff dst-in operation).
    ///
    /// All pixel types with color channels are expected to be pre-multiplied.
    pub fn dstIn(dst: Alpha8, src: Pixel) Alpha8 {
        const d = .{
            .a = @as(u32, @intCast(dst.a)),
        };
        return switch (src) {
            .rgb => .{
                .a = dst.a,
            },
            .rgba => |s| .{
                .a = @intCast(d.a * s.a / 255),
            },
            .alpha8 => |s| .{
                .a = @intCast(d.a * s.a / 255),
            },
        };
    }
};

test "pixel interface, fromPixel" {
    const rgb: RGB = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC };
    const rgba: RGBA = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC, .a = 0xDD };
    const alpha8: Alpha8 = .{ .a = 0xDD };

    try testing.expectEqual(RGB.fromPixel(.{ .rgb = rgb }), rgb);
    try testing.expectError(error.InvalidPixelFormat, RGB.fromPixel(.{ .rgba = rgba }));

    try testing.expectEqual(RGBA.fromPixel(.{ .rgba = rgba }), rgba);
    try testing.expectError(error.InvalidPixelFormat, RGBA.fromPixel(.{ .rgb = rgb }));

    try testing.expectEqual(Alpha8.fromPixel(.{ .alpha8 = alpha8 }), alpha8);
    try testing.expectError(error.InvalidPixelFormat, Alpha8.fromPixel(.{ .rgb = rgb }));
}

test "pixel interface, asPixel" {
    const rgb: RGB = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC };
    const rgba: RGBA = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC, .a = 0xDD };
    const alpha8: Alpha8 = .{ .a = 0xDD };

    try testing.expectEqual(Pixel{ .rgb = rgb }, rgb.asPixel());
    try testing.expectEqual(Pixel{ .rgba = rgba }, rgba.asPixel());
    try testing.expectEqual(Pixel{ .alpha8 = alpha8 }, alpha8.asPixel());
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

    try testing.expectEqual(rgb_expected, RGB.average(&rgb));
    try testing.expectEqual(rgba_expected, RGBA.average(&rgba));
    try testing.expectEqual(alpha8_expected, Alpha8.average(&alpha8));
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
