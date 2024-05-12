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
        if (mem.eql(u8, name, "black")) {
            return .{ .r = 0, .g = 0, .b = 0 };
        } else if (mem.eql(u8, name, "silver")) {
            return .{ .r = 192, .g = 192, .b = 192 };
        } else if (mem.eql(u8, name, "gray")) {
            return .{ .r = 128, .g = 128, .b = 128 };
        } else if (mem.eql(u8, name, "white")) {
            return .{ .r = 255, .g = 255, .b = 255 };
        } else if (mem.eql(u8, name, "maroon")) {
            return .{ .r = 128, .g = 0, .b = 0 };
        } else if (mem.eql(u8, name, "red")) {
            return .{ .r = 255, .g = 0, .b = 0 };
        } else if (mem.eql(u8, name, "purple")) {
            return .{ .r = 128, .g = 0, .b = 128 };
        } else if (mem.eql(u8, name, "fuchsia")) {
            return .{ .r = 255, .g = 0, .b = 255 };
        } else if (mem.eql(u8, name, "green")) {
            return .{ .r = 0, .g = 128, .b = 0 };
        } else if (mem.eql(u8, name, "lime")) {
            return .{ .r = 0, .g = 255, .b = 0 };
        } else if (mem.eql(u8, name, "olive")) {
            return .{ .r = 128, .g = 128, .b = 0 };
        } else if (mem.eql(u8, name, "yellow")) {
            return .{ .r = 255, .g = 255, .b = 0 };
        } else if (mem.eql(u8, name, "navy")) {
            return .{ .r = 0, .g = 0, .b = 128 };
        } else if (mem.eql(u8, name, "blue")) {
            return .{ .r = 0, .g = 0, .b = 255 };
        } else if (mem.eql(u8, name, "teal")) {
            return .{ .r = 0, .g = 128, .b = 128 };
        } else if (mem.eql(u8, name, "aqua")) {
            return .{ .r = 0, .g = 255, .b = 255 };
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
