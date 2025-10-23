const compositor = @import("../../compositor.zig");
const pixel = @import("../../pixel.zig");

/// Returns true if the operator can be fast-pathed on the source by writing
/// the source pixel directly to the surface.
///
/// Note that all operators that can be fast-pathed are also integer
/// pipeline operations.
pub fn fillReducesToSource(op: compositor.Operator, px: pixel.Pixel) bool {
    return switch (op) {
        .src => true,
        .src_over => px.isOpaque(),
        else => false,
    };
}
