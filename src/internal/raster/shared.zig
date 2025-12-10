const compositor = @import("../../compositor.zig");
const pixel = @import("../../pixel.zig");

const Surface = @import("../../surface.zig").Surface;
const Pattern = @import("../../pattern.zig").Pattern;

/// Composites opaque pixels, fast-pathing if the operator reduces to the
/// source pixel.
pub fn compositeOpaque(
    operator: compositor.Operator,
    surface: *Surface,
    pattern: *const Pattern,
    x: i32,
    y: i32,
    len: usize,
    precision: compositor.Precision,
) void {
    if (operator == .clear) {
        surface.clearStride(x, y, len);
    } else if (pattern.* == .opaque_pattern and
        fillReducesToSource(operator, pattern.opaque_pattern.pixel))
    {
        surface.paintStride(x, y, len, pattern.opaque_pattern.pixel);
    } else {
        const dst_stride = surface.getStride(x, y, len);
        if (dst_stride.pxLen() == 0) {
            return;
        }
        compositor.StrideCompositor.run(dst_stride, &.{.{
            .operator = operator,
            .src = switch (pattern.*) {
                .opaque_pattern => .{ .pixel = pattern.opaque_pattern.pixel },
                .gradient => |g| .{ .gradient = .{
                    .underlying = g,
                    .x = x,
                    .y = y,
                } },
                .dither => .{ .dither = .{
                    .underlying = pattern.dither,
                    .x = x,
                    .y = y,
                } },
            },
        }}, .{ .precision = precision });
    }
}

/// Composites pixels with opacity, fast-pathing if the operator reduces to the
/// source pixel.
pub fn compositeOpacity(
    operator: compositor.Operator,
    surface: *Surface,
    pattern: *const Pattern,
    x: i32,
    y: i32,
    len: usize,
    precision: compositor.Precision,
    opacity: u8,
) void {
    if (operator == .clear) {
        surface.clearStride(x, y, len);
    } else if (pattern.* == .opaque_pattern and
        fillReducesToSource(operator, pattern.opaque_pattern.pixel))
    {
        surface.compositeStride(
            x,
            y,
            len,
            pattern.opaque_pattern.pixel,
            operator,
            opacity,
        );
    } else {
        const dst_stride = surface.getStride(x, y, len);
        if (dst_stride.pxLen() == 0) {
            return;
        }
        const mask_px: pixel.Pixel = .{ .alpha8 = .{
            .a = opacity,
        } };
        compositor.StrideCompositor.run(dst_stride, &.{
            .{
                .operator = .dst_in,
                .dst = switch (pattern.*) {
                    .opaque_pattern => .{ .pixel = pattern.opaque_pattern.pixel },
                    .gradient => |g| .{ .gradient = .{
                        .underlying = g,
                        .x = x,
                        .y = y,
                    } },
                    .dither => .{ .dither = .{
                        .underlying = pattern.dither,
                        .x = x,
                        .y = y,
                    } },
                },
                .src = .{ .pixel = mask_px },
            },
            .{
                .operator = operator,
            },
        }, .{ .precision = precision });
    }
}

/// Returns true if the operator can be fast-pathed on the source by writing
/// the source pixel directly to the surface.
///
/// Note that all operators that can be fast-pathed are also integer
/// pipeline operations.
fn fillReducesToSource(op: compositor.Operator, px: pixel.Pixel) bool {
    return switch (op) {
        .src => true,
        .src_over => px.isOpaque(),
        else => false,
    };
}
