//! Case: Renders unclosed lines with miters.
const debug = @import("std").debug;
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "015_stroke_miter.png";

pub fn render(alloc: mem.Allocator) !z2d.Surface {
    const width = 800;
    const height = 400;
    const sfc = try z2d.Surface.init(.image_surface_rgb, alloc, width, height);

    var context = z2d.DrawContext.init(sfc);
    const pixel = .{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } }; // White on black
    try context.setPattern(.{ .opaque_pattern = .{ .pixel = pixel } });

    var path = z2d.PathOperation.init(alloc, &context);
    defer path.deinit();

    // Down and to the right
    try path.moveTo(.{
        .x = 10,
        .y = 10,
    });
    try path.lineTo(.{
        .x = 30,
        .y = 30,
    });
    try path.lineTo(.{
        .x = 10,
        .y = 50,
    });

    try path.stroke();

    return sfc;
}
