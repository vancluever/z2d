const testing = @import("std").testing;

const surfacepkg = @import("surface.zig");
const patternpkg = @import("pattern.zig");
const pixelpkg = @import("pixel.zig");
const options = @import("options.zig");

/// The draw context, which connects patterns to surfaces, holds other state
/// data, and is used to dispatch drawing operations.
pub const DrawContext = struct {
    /// The underlying pattern.
    ///
    /// read-only: should not be modified directly.
    pattern: patternpkg.Pattern,

    /// The underlying surface.
    ///
    /// read-only: should not be modified directly.
    surface: surfacepkg.Surface,

    /// The current line width for drawing operations, in pixels. This value is
    /// taken at call time during stroke operations in a path, and has no
    /// effect during path construction.
    ///
    /// The default line width is 2.0.
    ///
    /// read-write: can be set directly, but can also be set with setLineWidth.
    line_width: f64,

    /// The current fill rule. The default is non_zero.
    ///
    /// read-write: can be set directly, but can also be set with setFillRule.
    fill_rule: options.FillRule,

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
            .line_width = 2.0,
            .fill_rule = .non_zero,
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
                if (p.pixel != self.surface.getFormat()) {
                    return error.IncompatiblePatternForSurface;
                }
            },
        }

        self.pattern = pattern;
    }

    /// Sets the current line width for drawing operations, in pixels. This value is
    /// taken at call time during stroke operations in a path, and has no
    /// effect during path construction.
    ///
    /// The default line width is 2.0.
    pub fn setLineWidth(self: *DrawContext, value: f64) void {
        self.line_width = value;
    }

    /// Sets the rule for filling operations. The default is non_zero.
    pub fn setFillRule(self: *DrawContext, value: options.FillRule) void {
        self.fill_rule = value;
    }
};

test "DrawContext, basic" {
    const sfc = try surfacepkg.Surface.init(.image_surface_rgba, testing.allocator, 1, 1);
    defer sfc.deinit();

    const ctx = DrawContext.init(sfc);
    try ctx.surface.putPixel(0, 0, try ctx.pattern.getPixel(0, 0));
    const expected_px: pixelpkg.Pixel = .{ .rgba = .{ .r = 0x00, .g = 0x00, .b = 0x00, .a = 0xFF } };
    try testing.expectEqual(expected_px, try ctx.surface.getPixel(0, 0));
}

test "DrawContext, setPattern, OK" {
    const sfc = try surfacepkg.Surface.init(.image_surface_rgb, testing.allocator, 1, 1);
    defer sfc.deinit();

    var ctx = DrawContext.init(sfc);
    const expected_px: pixelpkg.Pixel = .{ .rgb = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC } };
    try ctx.setPattern(.{ .opaque_pattern = .{ .pixel = expected_px } });
    try ctx.surface.putPixel(0, 0, try ctx.pattern.getPixel(0, 0));
    try testing.expectEqual(expected_px, try ctx.surface.getPixel(0, 0));
}

test "DrawContext, setPattern, invalid pixel format" {
    const sfc = try surfacepkg.Surface.init(.image_surface_rgba, testing.allocator, 1, 1);
    defer sfc.deinit();

    var ctx = DrawContext.init(sfc);
    const px: pixelpkg.Pixel = .{ .rgb = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC } };
    try testing.expectError(
        error.IncompatiblePatternForSurface,
        ctx.setPattern(.{ .opaque_pattern = .{ .pixel = px } }),
    );
}
