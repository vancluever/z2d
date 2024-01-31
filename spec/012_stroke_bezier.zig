//! Case: Renders and strokes a bezier curve on a 300x300 surface.
//!
//! This bezier is not closed.
const debug = @import("std").debug;
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "012_stroke_bezier.png";

pub fn render(alloc: mem.Allocator) !z2d.Surface {
    const width = 300;
    const height = 300;
    const sfc = try z2d.Surface.init(.image_surface_rgb, alloc, width, height);

    var context = z2d.DrawContext.init(sfc);
    const pixel = .{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } }; // White on black
    try context.setPattern(.{ .opaque_pattern = .{ .pixel = pixel } });

    var path = z2d.PathOperation.init(alloc, &context);
    defer path.deinit();

    const p0: z2d.Point = .{ .x = 19, .y = 249 };
    const p1: z2d.Point = .{ .x = 89, .y = 49 };
    const p2: z2d.Point = .{ .x = 209, .y = 49 };
    const p3: z2d.Point = .{ .x = 279, .y = 249 };
    try path.moveTo(p0); // 1
    try path.curveTo(p1, p2, p3); // 3

    try path.stroke();

    return sfc;
}
