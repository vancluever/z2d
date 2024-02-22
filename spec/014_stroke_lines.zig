//! Case: Renders multiple lines with the default thickness in different
//! directions, unclosed.
const debug = @import("std").debug;
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "014_stroke_lines.png";

pub fn render(alloc: mem.Allocator) !z2d.Surface {
    const width = 800;
    const height = 400;
    const sfc = try z2d.Surface.init(.image_surface_rgb, alloc, width, height);

    var context = z2d.DrawContext.init(sfc);
    const pixel = .{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } }; // White on black
    try context.setPattern(.{ .opaque_pattern = .{ .pixel = pixel } });

    var path = z2d.PathOperation.init(alloc, &context);
    defer path.deinit();

    // sub-canvas dimensions
    const sub_canvas_width = width / 4;
    const sub_canvas_height = height / 2;

    // Down and to the right
    const margin = 10;
    comptime var x_offset = 0;
    comptime var y_offset = 0;
    try path.moveTo(.{
        .x = x_offset + margin,
        .y = y_offset + margin,
    });
    try path.lineTo(.{
        .x = x_offset + sub_canvas_width - margin - 1,
        .y = y_offset + sub_canvas_height - margin - 1,
    });

    // Up and to the right
    x_offset = sub_canvas_width;
    try path.moveTo(.{
        .x = x_offset + margin,
        .y = y_offset + sub_canvas_height - margin - 1,
    });
    try path.lineTo(.{
        .x = x_offset + sub_canvas_width - margin - 1,
        .y = y_offset + margin,
    });

    // Down and to the left
    x_offset = 0;
    y_offset = sub_canvas_height;
    try path.moveTo(.{
        .x = x_offset + sub_canvas_width - margin - 1,
        .y = y_offset + margin,
    });
    try path.lineTo(.{
        .x = x_offset + margin,
        .y = y_offset + sub_canvas_height - margin - 1,
    });

    // Up and to the left
    x_offset = sub_canvas_width;
    y_offset = sub_canvas_height;
    try path.moveTo(.{
        .x = x_offset + sub_canvas_width - margin - 1,
        .y = y_offset + sub_canvas_height - margin - 1,
    });
    try path.lineTo(.{
        .x = x_offset + margin,
        .y = y_offset + margin,
    });

    // Horizontal (left -> right)
    x_offset = sub_canvas_width * 2;
    y_offset = 0;
    try path.moveTo(.{
        .x = x_offset + margin,
        .y = y_offset + sub_canvas_height / 2,
    });
    try path.lineTo(.{
        .x = x_offset + sub_canvas_width - margin - 1,
        .y = y_offset + sub_canvas_height / 2,
    });

    // Vertical (up -> down)
    x_offset = sub_canvas_width * 2;
    y_offset = sub_canvas_height;
    try path.moveTo(.{
        .x = x_offset + sub_canvas_width / 2,
        .y = y_offset + margin,
    });
    try path.lineTo(.{
        .x = x_offset + sub_canvas_width / 2,
        .y = y_offset + sub_canvas_height - margin - 1,
    });

    // Vertical (down -> up)
    x_offset = sub_canvas_width * 3;
    y_offset = 0;
    try path.moveTo(.{
        .x = x_offset + sub_canvas_width / 2,
        .y = y_offset + sub_canvas_height - margin - 1,
    });
    try path.lineTo(.{
        .x = x_offset + sub_canvas_width / 2,
        .y = y_offset + margin,
    });

    // Horizontal (right -> left)
    x_offset = sub_canvas_width * 3;
    y_offset = sub_canvas_height;
    try path.moveTo(.{
        .x = x_offset + sub_canvas_width - margin - 1,
        .y = y_offset + sub_canvas_height / 2,
    });
    try path.lineTo(.{
        .x = x_offset + margin,
        .y = y_offset + sub_canvas_height / 2,
    });

    try path.stroke();

    return sfc;
}
