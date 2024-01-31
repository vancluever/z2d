//! Case: Renders and strokes a square on a 300x300 surface.
const debug = @import("std").debug;
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "009_stroke_square.png";

pub fn render(alloc: mem.Allocator) !z2d.Surface {
    const width = 300;
    const height = 300;
    const sfc = try z2d.Surface.init(.image_surface_rgb, alloc, width, height);

    var context = z2d.DrawContext.init(sfc);
    const pixel = .{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } }; // White on black
    try context.setPattern(.{ .opaque_pattern = .{ .pixel = pixel } });

    var path = z2d.PathOperation.init(alloc, &context);
    defer path.deinit();

    const margin = 50;
    try path.moveTo(.{ .x = 0 + margin, .y = 0 + margin });
    try path.lineTo(.{ .x = width - margin - 1, .y = 0 + margin });
    try path.lineTo(.{ .x = width - margin - 1, .y = height - margin - 1 });
    try path.lineTo(.{ .x = 0 + margin, .y = height - margin - 1 });
    try path.closePath();

    try path.stroke();

    return sfc;
}
