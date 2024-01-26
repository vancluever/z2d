const testing = @import("std").testing;

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

    /// Returns this pixel as an interface.
    pub fn asPixel(self: RGB) Pixel {
        return .{ .rgb = self };
    }
};

/// Describes a 32-bit RGBA format.
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

    /// Returns this pixel as an interface.
    pub fn asPixel(self: RGBA) Pixel {
        return .{ .rgba = self };
    }
};

/// Format descriptors for the pixel formats supported by the library:
///
/// * .rgba is 24-bit truecolor as a 8-bit depth RGB, *with* alpha channel.
/// * .rgb is 24-bit truecolor as a 8-bit depth RGB, *without* alpha channel.
pub const Format = enum {
    rgb,
    rgba,
};

/// Represents an interface as a union of the pixel formats.
pub const Pixel = union(Format) {
    rgb: RGB,
    rgba: RGBA,
};

test "pixel interface, fromPixel" {
    const rgb: RGB = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC };
    const rgba: RGBA = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC, .a = 0xDD };

    try testing.expectEqual(RGB.fromPixel(.{ .rgb = rgb }), rgb);
    try testing.expectError(error.InvalidPixelFormat, RGB.fromPixel(.{ .rgba = rgba }));

    try testing.expectEqual(RGBA.fromPixel(.{ .rgba = rgba }), rgba);
    try testing.expectError(error.InvalidPixelFormat, RGBA.fromPixel(.{ .rgb = rgb }));
}

test "pixel interface, asPixel" {
    const rgb: RGB = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC };
    const rgba: RGBA = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC, .a = 0xDD };

    try testing.expectEqual(Pixel{ .rgb = rgb }, rgb.asPixel());
    try testing.expectEqual(Pixel{ .rgba = rgba }, rgba.asPixel());
}
