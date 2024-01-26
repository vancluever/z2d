const testing = @import("std").testing;

const surfacepkg = @import("surface.zig");
const patternpkg = @import("pattern.zig");
const pixelpkg = @import("pixel.zig");

/// The draw context, which connects patterns to surfaces, holds other state
/// data, and is used to dispatch drawing operations.
pub const DrawContext = struct {
    /// The underlying pattern. Do not set directly, use setPattern, which will
    /// do compatibility checks.
    pattern: patternpkg.Pattern,

    /// The underlying surface. Setting this value after initialization is
    /// undefined behavior. Do not set directly, use init to do so.
    surface: surfacepkg.Surface,

    /// Creates a new context with the underlying surface.
    ///
    /// The initial pattern is set to opaque black, appropriate to the pixel
    /// format of the surface.
    pub fn init(surface: surfacepkg.Surface) DrawContext {
        const px: pixelpkg.Pixel = switch (surface) {
            .image_surface_rgb => .{ .rgb = .{ .r = 0x00, .g = 0x00, .b = 0x00 } },
            .image_surface_rgba => .{ .rgba = .{ .r = 0x00, .g = 0x00, .b = 0x00, .a = 0xFF } },
        };
        return .{
            .pattern = .{ .opaque_pattern = .{ .pixel = px } },
            .surface = surface,
        };
    }

    /// Sets the pattern on the context to the supplied pattern.
    ///
    /// Returns an error if the pattern would be incompatible for the context's
    /// underlying surface.
    pub fn setPattern(self: *DrawContext, pattern: patternpkg.Pattern) !void {
        // Do a simple check for now on the underlying pattern interface to
        // check for compatibility, with the surface's pixel format. This will
        // eventually change so that we can do transformations, etc.
        switch (pattern) {
            .opaque_pattern => |p| {
                if (p.pixel != self.surface.format()) {
                    return error.IncompatiblePatternForSurface;
                }
            },
        }

        self.pattern = pattern;
    }
};

test "DrawContext, basic" {
    const sfc = try surfacepkg.createSurface(.image_surface_rgba, testing.allocator, 1, 1);
    defer sfc.deinit();

    const ctx = DrawContext.init(sfc);
    try ctx.surface.putPixel(0, 0, try ctx.pattern.getPixel(0, 0));
    const expected_px: pixelpkg.Pixel = .{ .rgba = .{ .r = 0x00, .g = 0x00, .b = 0x00, .a = 0xFF } };
    try testing.expectEqual(expected_px, try ctx.surface.getPixel(0, 0));
}

test "DrawContext, setPattern, OK" {
    const sfc = try surfacepkg.createSurface(.image_surface_rgb, testing.allocator, 1, 1);
    defer sfc.deinit();

    var ctx = DrawContext.init(sfc);
    const expected_px: pixelpkg.Pixel = .{ .rgb = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC } };
    try ctx.setPattern(.{ .opaque_pattern = .{ .pixel = expected_px } });
    try ctx.surface.putPixel(0, 0, try ctx.pattern.getPixel(0, 0));
    try testing.expectEqual(expected_px, try ctx.surface.getPixel(0, 0));
}

test "DrawContext, setPattern, invalid pixel format" {
    const sfc = try surfacepkg.createSurface(.image_surface_rgba, testing.allocator, 1, 1);
    defer sfc.deinit();

    var ctx = DrawContext.init(sfc);
    const px: pixelpkg.Pixel = .{ .rgb = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC } };
    try testing.expectError(
        error.IncompatiblePatternForSurface,
        ctx.setPattern(.{ .opaque_pattern = .{ .pixel = px } }),
    );
}
