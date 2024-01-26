const testing = @import("std").testing;

const surfacepkg = @import("surface.zig");
const patternpkg = @import("pattern.zig");
const pixelpkg = @import("pixel.zig");

/// The draw context, which connects patterns to surfaces, holds other state
/// data, and is used to dispatch drawing operations.
const DrawContext = struct {
    pattern: patternpkg.Pattern,
    surface: surfacepkg.Surface,

    pub fn init(surface: surfacepkg.Surface) DrawContext {
        // Set set the initial pattern as opaque black, depending on the pixel
        // type.
        const px: pixelpkg.Pixel = switch (surface) {
            .image_surface_rgb => .{ .rgb = .{ .r = 0x00, .g = 0x00, .b = 0x00 } },
            .image_surface_rgba => .{ .rgba = .{ .r = 0x00, .g = 0x00, .b = 0x00, .a = 0xFF } },
        };
        return .{
            .pattern = .{ .opaque_pattern = .{ .pixel = px } },
            .surface = surface,
        };
    }
};

test "DrawContext" {
    const sfc = try surfacepkg.createSurface(.image_surface_rgba, testing.allocator, 1, 1);
    defer sfc.deinit();

    const ctx = DrawContext.init(sfc);
    try ctx.surface.putPixel(0, 0, try ctx.pattern.getPixel(0, 0));
    const expected_px: pixelpkg.Pixel = .{ .rgba = .{ .r = 0x00, .g = 0x00, .b = 0x00, .a = 0xFF } };
    try testing.expectEqual(expected_px, try ctx.surface.getPixel(0, 0));
}
