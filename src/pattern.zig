// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024 Chris Marchesi

//! Pattern types and interfaces. Patterns are sources of pixel data, such as
//! "opaque" single-pixel patterns, gradients, or even whole other surfaces.
//!
//! Currently, only opaque patterns are supported, others are WIP.
const testing = @import("std").testing;

const Pixel = @import("pixel.zig").Pixel;

/// Interface tags for pattern types.
pub const PatternType = enum {
    opaque_pattern,
};

/// Represents an interface as a union of all patterns.
pub const Pattern = union(PatternType) {
    opaque_pattern: OpaquePattern,

    /// Gets the pixel data at the co-ordinates specified.
    pub fn getPixel(self: Pattern, x: i32, y: i32) Pixel {
        _ = x;
        _ = y;
        return switch (self) {
            .opaque_pattern => |s| s.pixel,
        };
    }
};

/// A simple opaque color pattern that writes the set color to every pixel.
pub const OpaquePattern = struct {
    /// The underlying pixel for this pattern.
    pixel: Pixel,
};

test "OpaquePattern, as interface" {
    const px: Pixel = .{ .rgb = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC } };
    const pt: Pattern = .{ .opaque_pattern = .{ .pixel = px } };
    try testing.expectEqual(px, pt.getPixel(1, 1));
}
