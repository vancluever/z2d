//! Case: Renders and fills a trapezoid on a 300x300 surface.
const debug = @import("std").debug;
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "005_fill_trapezoid.png";

pub fn render(alloc: mem.Allocator) !z2d.Surface {
    const width = 300;
    const height = 300;
    const sfc = try z2d.Surface.init(.image_surface_rgb, alloc, width, height);

    var context = z2d.DrawContext.init(sfc);
    const pixel = .{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } }; // White on black
    try context.setPattern(z2d.Pattern.initOpaque(pixel));

    var path = z2d.PathOperation.init(alloc, &context);
    defer path.deinit();

    const margin_top = 89;
    const margin_bottom = 50;
    const margin_y = 100;
    try path.moveTo(.{ .x = 0 + margin_top, .y = 0 + margin_y });
    try path.lineTo(.{ .x = width - margin_top - 1, .y = 0 + margin_y });
    try path.lineTo(.{ .x = width - margin_bottom - 1, .y = height - margin_y - 1 });
    try path.lineTo(.{ .x = 0 + margin_bottom, .y = height - margin_y - 1 });
    try path.closePath();

    try path.fill();

    return sfc;
}
