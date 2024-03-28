//! Case: Renders and strokes stacked beziers of varying thickness on a 300x300
//! surface.
//!
//! The beziers are not closed.
const debug = @import("std").debug;
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "012_stroke_bezier";

pub fn render(alloc: mem.Allocator, aa_mode: z2d.AntiAliasMode) !z2d.Surface {
    const width = 300;
    const height = 300;
    const sfc = try z2d.Surface.init(.image_surface_rgb, alloc, width, height);

    var context = z2d.DrawContext.init(sfc);
    const pixel = .{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } }; // White on black
    try context.setPattern(z2d.Pattern.initOpaque(pixel));
    context.setAntiAlias(aa_mode);

    var path = z2d.PathOperation.init(alloc, &context);
    defer path.deinit();

    var p0: z2d.Point = .{ .x = 19, .y = 149 };
    var p1: z2d.Point = .{ .x = 89, .y = 0 };
    var p2: z2d.Point = .{ .x = 209, .y = 0 };
    var p3: z2d.Point = .{ .x = 279, .y = 149 };
    try path.moveTo(p0);
    try path.curveTo(p1, p2, p3);
    try path.stroke();

    context.setLineWidth(6);
    path.reset();
    p0 = .{ .x = 19, .y = 199 };
    p1 = .{ .x = 89, .y = 24 };
    p2 = .{ .x = 209, .y = 24 };
    p3 = .{ .x = 279, .y = 199 };
    try path.moveTo(p0);
    try path.curveTo(p1, p2, p3);
    try path.stroke();

    context.setLineWidth(10);
    path.reset();
    p0 = .{ .x = 19, .y = 249 };
    p1 = .{ .x = 89, .y = 49 };
    p2 = .{ .x = 209, .y = 49 };
    p3 = .{ .x = 279, .y = 249 };
    try path.moveTo(p0);
    try path.curveTo(p1, p2, p3);
    try path.stroke();

    return sfc;
}
