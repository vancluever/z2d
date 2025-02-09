// SPDX-License-Identifier: 0BSD
//   Copyright © 2024 Chris Marchesi

//! Case: Renders multiple lines with the default thickness in different
//! directions, unclosed. Dashed version.
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "054_stroke_lines_dashed";

pub fn render(alloc: mem.Allocator, aa_mode: z2d.options.AntiAliasMode) !z2d.Surface {
    const width = 800;
    const height = 400;
    var sfc = try z2d.Surface.init(.image_surface_rgb, alloc, width, height);

    var context = try z2d.Context.init(alloc, &sfc);
    defer context.deinit();
    context.setSourceToPixel(.{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } });
    context.setAntiAliasingMode(aa_mode);
    context.setDashes(&.{ 10, 5 });

    // sub-canvas dimensions
    const sub_canvas_width = width / 4;
    const sub_canvas_height = height / 2;

    // Down and to the right
    const margin = 10;
    comptime var x_offset = 0;
    comptime var y_offset = 0;
    try context.moveTo(x_offset + margin, y_offset + margin);
    try context.lineTo(x_offset + sub_canvas_width - margin - 1, y_offset + sub_canvas_height - margin - 1);

    // Up and to the right
    x_offset = sub_canvas_width;
    try context.moveTo(x_offset + margin, y_offset + sub_canvas_height - margin - 1);
    try context.lineTo(x_offset + sub_canvas_width - margin - 1, y_offset + margin);

    // Down and to the left
    x_offset = 0;
    y_offset = sub_canvas_height;
    try context.moveTo(x_offset + sub_canvas_width - margin - 1, y_offset + margin);
    try context.lineTo(x_offset + margin, y_offset + sub_canvas_height - margin - 1);

    // Up and to the left
    x_offset = sub_canvas_width;
    y_offset = sub_canvas_height;
    try context.moveTo(x_offset + sub_canvas_width - margin - 1, y_offset + sub_canvas_height - margin - 1);
    try context.lineTo(x_offset + margin, y_offset + margin);

    // Horizontal (left -> right)
    x_offset = sub_canvas_width * 2;
    y_offset = 0;
    try context.moveTo(x_offset + margin, y_offset + sub_canvas_height / 2);
    try context.lineTo(x_offset + sub_canvas_width - margin - 1, y_offset + sub_canvas_height / 2);

    // Vertical (up -> down)
    x_offset = sub_canvas_width * 2;
    y_offset = sub_canvas_height;
    try context.moveTo(x_offset + sub_canvas_width / 2, y_offset + margin);
    try context.lineTo(x_offset + sub_canvas_width / 2, y_offset + sub_canvas_height - margin - 1);

    // Vertical (down -> up)
    x_offset = sub_canvas_width * 3;
    y_offset = 0;
    try context.moveTo(x_offset + sub_canvas_width / 2, y_offset + sub_canvas_height - margin - 1);
    try context.lineTo(x_offset + sub_canvas_width / 2, y_offset + margin);

    // Horizontal (right -> left)
    x_offset = sub_canvas_width * 3;
    y_offset = sub_canvas_height;
    try context.moveTo(x_offset + sub_canvas_width - margin - 1, y_offset + sub_canvas_height / 2);
    try context.lineTo(x_offset + margin, y_offset + sub_canvas_height / 2);

    try context.stroke();

    return sfc;
}
