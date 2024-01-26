const mem = @import("std").mem;

const testing = @import("std").testing;

const pixelpkg = @import("pixel.zig");

/// Interface tags for pattern types.
pub const PatternType = enum {
    opaque_pattern,
};

/// Represents an interface as a union of all patterns.
pub const Pattern = union(PatternType) {
    opaque_pattern: *OpaquePattern,

    /// Releases the underlying pattern reference, and anything else as
    /// applicable. The pattern is invalid for use afterwards.
    pub fn deinit(self: Pattern) void {
        return switch (self) {
            .opaque_pattern => |s| s.alloc.destroy(s),
        };
    }

    /// Gets the pixel data at the co-ordinates specified.
    pub fn getPixel(self: Pattern, x: u32, y: u32) !pixelpkg.Pixel {
        return switch (self) {
            .opaque_pattern => |s| s.getPixel(x, y),
        };
    }
};

/// Creates an opaque pattern as an interface.
///
/// The caller owns the memory, so make sure to call deinit on the pattern to
/// release it.
pub fn createOpaquePattern(
    alloc: mem.Allocator,
    pixel: pixelpkg.Pixel,
) !Pattern {
    const op = try alloc.create(OpaquePattern);
    op.* = .{ .alloc = alloc, .pixel = pixel };
    return op.asPatternInterface();
}

/// A simple opaque color pattern that writes the set color to every pixel.
pub const OpaquePattern = struct {
    /// The underlying allocator, Should not be used.
    alloc: mem.Allocator,

    /// The underlying pixel for this pattern.
    pixel: pixelpkg.Pixel,

    /// Returns a Pattern interface for this surface.
    pub fn asPatternInterface(self: *OpaquePattern) Pattern {
        return .{ .opaque_pattern = self };
    }

    /// Gets the pixel data at the co-ordinates specified.
    ///
    /// Note that OpaquePattern returns its underlying pixel for every
    /// co-ordinate passed; the co-ordinates specified are only for interface
    /// implementation.
    pub fn getPixel(self: *OpaquePattern, x: u32, y: u32) !pixelpkg.Pixel {
        // Note that we just discard x and y as the same pixel is returned for
        // every location.
        _ = x;
        _ = y;
        return self.pixel;
    }
};

test "OpaquePattern, as interface" {
    const px: pixelpkg.Pixel = .{ .rgb = .{ .r = 0xAA, .g = 0xBB, .c = 0xCC } };
    const pt = try createOpaquePattern(testing.allocator, px);
    defer pt.deinit();
    try testing.expectEqual(px, pt.getPixel(1, 1));
}
