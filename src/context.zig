const surfacepkg = @import("surface.zig");
const patternpkg = @import("pattern.zig");

/// The draw context, which connects patterns to surfaces, holds other state
/// data, and is used to dispatch drawing operations.
const DrawContext = struct {
    pattern: patternpkg.Pattern,
    surface: surfacepkg.Surface,
};
