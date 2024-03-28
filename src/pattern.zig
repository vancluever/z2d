const testing = @import("std").testing;

const pixelpkg = @import("pixel.zig");

/// Interface tags for pattern types.
pub const PatternType = enum {
    opaque_pattern,
};

/// Represents an interface as a union of all patterns.
pub const Pattern = union(PatternType) {
    opaque_pattern: OpaquePattern,

    /// Gets the pixel data at the co-ordinates specified.
    pub fn getPixel(self: Pattern, x: u32, y: u32) !pixelpkg.Pixel {
        _ = x;
        _ = y;
        return switch (self) {
            .opaque_pattern => |s| s.pixel,
        };
    }

    /// Initializes a new opaque pattern with the supplied pixel.
    ///
    /// If the pixel has both color an alpha channels (e.g., RGBA), do not
    /// supply the value pre-multiplied, it will be multiplied by this
    /// function.
    pub fn initOpaque(px: pixelpkg.Pixel) Pattern {
        return .{
            .opaque_pattern = .{
                .pixel = switch (px) {
                    .rgba => |rgba| rgba.multiply().asPixel(),
                    else => px,
                },
            },
        };
    }
};

/// A simple opaque color pattern that writes the set color to every pixel.
pub const OpaquePattern = struct {
    /// The underlying pixel for this pattern.
    pixel: pixelpkg.Pixel,
};

test "OpaquePattern, as interface" {
    const px: pixelpkg.Pixel = .{ .rgb = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC } };
    const pt: Pattern = .{ .opaque_pattern = .{ .pixel = px } };
    try testing.expectEqual(px, pt.getPixel(1, 1));
}
