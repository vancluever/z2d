const mem = @import("std").mem;
const testing = @import("std").testing;

/// Format descriptors for the pixel formats supported by the library:
///
/// * .rgba is 24-bit truecolor as an 8-bit depth RGB, *with* alpha channel.
/// * .rgb is 24-bit truecolor as an 8-bit depth RGB, *without* alpha channel.
/// * .alpha8 is an 8-bit alpha channel.
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

    /// Returns an average of the pixels in the supplied slice.
    ///
    /// The average of a zero-length slice is pure black.
    pub fn average(ps: []const RGB) RGB {
        if (ps.len == 0) return mem.zeroes(RGB);

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
/// Note that depending on where this value occurs, it may or may not be
/// pre-multiplied. During operations where the value is directly supplied
/// (e.g., direct getPixel and putPixel on a surface, or as a value in
/// OpaquePattern), the value will not be pre-multiplied. However, compositing
/// operations on a surface will assume that the values are pre-multiplied. As
/// such, care should be taken when working with RGBA surfaces directly using
/// getPixel and putPixel.
pub const RGBA = packed struct(u32) {
    r: u8,
    g: u8,
    b: u8,
    a: u8,

    /// The format descriptor for this pixel format.
    pub const format: Format = .rgba;

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
        if (ps.len == 0) return mem.zeroes(RGBA);

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
        if (ps.len == 0) return mem.zeroes(Alpha8);

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
