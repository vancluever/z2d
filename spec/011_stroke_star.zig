//! Case: Renders and strokes a star on a 300x300 surface.
//!
//! Note that this test also validates that we always fill strokes using the
//! non-zero rule, since drawing a star means tracing a path that overlaps as
//! you move from point to point.
const debug = @import("std").debug;
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "011_stroke_star.png";

pub fn render(alloc: mem.Allocator) !z2d.Surface {
    const width = 300;
    const height = 300;
    const sfc = try z2d.Surface.init(.image_surface_rgb, alloc, width, height);

    var context = z2d.DrawContext.init(sfc);
    const pixel = .{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } }; // White on black
    try context.setPattern(.{ .opaque_pattern = .{ .pixel = pixel } });
    context.setLineWidth(6); // Triple line width to detect gaps easier

    var path = z2d.PathOperation.init(alloc, &context);
    defer path.deinit();

    const margin = 20;
    const x_scale = 3;
    const y_scale = 5;
    // With all 5 points numbered 1-5 clockwise, we draw odds first (1, 3, 5),
    // then evens (4, 2), with the close connecting 4 and 1.
    try path.moveTo(.{ .x = width / 2, .y = 0 + margin }); // 1
    try path.lineTo(.{ .x = width - margin * x_scale - 1, .y = height - margin - 1 }); // 3
    try path.lineTo(.{ .x = 0 + margin, .y = 0 + margin * y_scale }); // 5
    try path.lineTo(.{ .x = width - margin - 1, .y = 0 + margin * y_scale }); // 2
    try path.lineTo(.{ .x = 0 + margin * x_scale, .y = height - margin - 1 }); // 4
    try path.closePath();

    try path.stroke();

    return sfc;
}