// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024 Chris Marchesi

//! Pattern types and interfaces. Patterns are sources of pixel data, such as
//! "opaque" single-pixel patterns, gradients, or even whole other surfaces.
//!
//! The main purpose the `Pattern` union serves is to unify all possible pixel
//! sources to be able to be passed through to the context via
//! `Context.setSource`. There is not much functionality here otherwise,
//! although `Pattern.getPixel` does serve as a baseline for all patterns to
//! assert that they fulfill their basic role of supplying pixel data for
//! drawing operations.
//!
//! For more in-depth pattern management, consult the packages holding the
//! primitives, such as `gradient`.
//!
//! Currently, only opaque patterns and linear gradients are supported, others
//! are WIP.
const testing = @import("std").testing;

const gradient = @import("gradient.zig");

const Pixel = @import("pixel.zig").Pixel;

/// Interface tags for pattern types.
pub const PatternType = enum {
    opaque_pattern,
    linear_gradient,
};

/// Represents an interface as a union of all patterns.
pub const Pattern = union(PatternType) {
    opaque_pattern: OpaquePattern,
    linear_gradient: *const gradient.Linear,

    /// Gets the pixel data at the co-ordinates specified.
    pub fn getPixel(self: Pattern, x: i32, y: i32) Pixel {
        return switch (self) {
            .opaque_pattern => |s| s.pixel,
            .linear_gradient => |s| s.getPixel(x, y),
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
