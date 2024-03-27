//! Case: Renders unclosed lines with rounded joins.
const debug = @import("std").debug;
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "018_stroke_square_spiral_round.png";

pub fn render(alloc: mem.Allocator) !z2d.Surface {
    const width = 240;
    const height = 260;
    const sfc = try z2d.Surface.init(.image_surface_rgb, alloc, width, height);

    var context = z2d.DrawContext.init(sfc);
    const pixel = .{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } }; // White on black
    try context.setPattern(z2d.Pattern.initOpaque(pixel));
    context.setLineWidth(10); // Minimum width to properly detect round joins (until we get AA)
    context.setLineJoin(.round);

    var path = z2d.PathOperation.init(alloc, &context);
    defer path.deinit();

    try path.moveTo(.{
        .x = 10,
        .y = 10,
    });
    try path.lineTo(.{
        .x = 100,
        .y = 20,
    });
    try path.lineTo(.{
        .x = 110,
        .y = 120,
    });
    try path.lineTo(.{
        .x = 10,
        .y = 110,
    });
    try path.lineTo(.{
        .x = 20,
        .y = 30,
    });
    try path.lineTo(.{
        .x = 90,
        .y = 40,
    });
    try path.lineTo(.{
        .x = 95,
        .y = 100,
    });
    try path.lineTo(.{
        .x = 30,
        .y = 95,
    });
    try path.lineTo(.{
        .x = 30,
        .y = 50,
    });
    try path.lineTo(.{
        .x = 80,
        .y = 50,
    });
    try path.lineTo(.{
        .x = 75,
        .y = 85,
    });
    try path.lineTo(.{
        .x = 45,
        .y = 80,
    });
    try path.lineTo(.{
        .x = 50,
        .y = 60,
    });
    try path.lineTo(.{
        .x = 65,
        .y = 70,
    });

    ////////////////////
    const x_offset = 120;

    try path.moveTo(.{
        .x = x_offset + 110,
        .y = 10,
    });
    try path.lineTo(.{
        .x = x_offset + 20,
        .y = 20,
    });
    try path.lineTo(.{
        .x = x_offset + 10,
        .y = 120,
    });
    try path.lineTo(.{
        .x = x_offset + 110,
        .y = 110,
    });
    try path.lineTo(.{
        .x = x_offset + 100,
        .y = 30,
    });
    try path.lineTo(.{
        .x = x_offset + 30,
        .y = 40,
    });
    try path.lineTo(.{
        .x = x_offset + 25,
        .y = 100,
    });
    try path.lineTo(.{
        .x = x_offset + 90,
        .y = 95,
    });
    try path.lineTo(.{
        .x = x_offset + 90,
        .y = 50,
    });
    try path.lineTo(.{
        .x = x_offset + 40,
        .y = 50,
    });
    try path.lineTo(.{
        .x = x_offset + 45,
        .y = 85,
    });
    try path.lineTo(.{
        .x = x_offset + 75,
        .y = 80,
    });
    try path.lineTo(.{
        .x = x_offset + 70,
        .y = 60,
    });
    try path.lineTo(.{
        .x = x_offset + 55,
        .y = 70,
    });

    ////////////////////
    const y_offset = 130;

    try path.moveTo(.{
        .x = 10,
        .y = y_offset + 120,
    });
    try path.lineTo(.{
        .x = 100,
        .y = y_offset + 110,
    });
    try path.lineTo(.{
        .x = 110,
        .y = y_offset + 10,
    });
    try path.lineTo(.{
        .x = 10,
        .y = y_offset + 20,
    });
    try path.lineTo(.{
        .x = 20,
        .y = y_offset + 100,
    });
    try path.lineTo(.{
        .x = 90,
        .y = y_offset + 90,
    });
    try path.lineTo(.{
        .x = 95,
        .y = y_offset + 30,
    });
    try path.lineTo(.{
        .x = 30,
        .y = y_offset + 35,
    });
    try path.lineTo(.{
        .x = 30,
        .y = y_offset + 80,
    });
    try path.lineTo(.{
        .x = 80,
        .y = y_offset + 80,
    });
    try path.lineTo(.{
        .x = 75,
        .y = y_offset + 45,
    });
    try path.lineTo(.{
        .x = 45,
        .y = y_offset + 50,
    });
    try path.lineTo(.{
        .x = 50,
        .y = y_offset + 70,
    });
    try path.lineTo(.{
        .x = 65,
        .y = y_offset + 60,
    });

    ////////////////////

    try path.moveTo(.{
        .x = x_offset + 110,
        .y = y_offset + 120,
    });
    try path.lineTo(.{
        .x = x_offset + 20,
        .y = y_offset + 110,
    });
    try path.lineTo(.{
        .x = x_offset + 10,
        .y = y_offset + 10,
    });
    try path.lineTo(.{
        .x = x_offset + 110,
        .y = y_offset + 20,
    });
    try path.lineTo(.{
        .x = x_offset + 100,
        .y = y_offset + 100,
    });
    try path.lineTo(.{
        .x = x_offset + 30,
        .y = y_offset + 90,
    });
    try path.lineTo(.{
        .x = x_offset + 25,
        .y = y_offset + 30,
    });
    try path.lineTo(.{
        .x = x_offset + 90,
        .y = y_offset + 35,
    });
    try path.lineTo(.{
        .x = x_offset + 90,
        .y = y_offset + 80,
    });
    try path.lineTo(.{
        .x = x_offset + 40,
        .y = y_offset + 80,
    });
    try path.lineTo(.{
        .x = x_offset + 45,
        .y = y_offset + 45,
    });
    try path.lineTo(.{
        .x = x_offset + 75,
        .y = y_offset + 50,
    });
    try path.lineTo(.{
        .x = x_offset + 70,
        .y = y_offset + 70,
    });
    try path.lineTo(.{
        .x = x_offset + 55,
        .y = y_offset + 60,
    });

    try path.stroke();

    return sfc;
}
