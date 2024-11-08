// SPDX-License-Identifier: 0BSD
//   Copyright © 2024 Chris Marchesi

//! Case: Renders and fills multiple shapes using a single path operation, used
//! to ensure we can do this without having to fill each polygon individually.
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "013_fill_combined";

pub fn render(alloc: mem.Allocator, aa_mode: z2d.options.AntiAliasMode) !z2d.Surface {
    const width = 600;
    const height = 400;
    var sfc = try z2d.Surface.init(.image_surface_rgb, alloc, width, height);

    var context = try z2d.Context.init(alloc, &sfc);
    defer context.deinit();
    context.setSource(.{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } });
    context.setAntiAliasingMode(aa_mode);

    // sub-canvas dimensions
    const sub_canvas_width = width / 3;
    const sub_canvas_height = height / 2;

    // Triangle
    comptime var margin = 10;
    try context.moveTo(0 + margin, 0 + margin);
    try context.lineTo(sub_canvas_width - margin - 1, 0 + margin);
    try context.lineTo(sub_canvas_width / 2 - 1, sub_canvas_height - margin - 1);
    try context.close();

    // Square
    margin = 50;
    comptime var x_offset = sub_canvas_width;
    try context.moveTo(x_offset + margin, 0 + margin);
    try context.lineTo(x_offset + sub_canvas_width - margin - 1, 0 + margin);
    try context.lineTo(x_offset + sub_canvas_width - margin - 1, sub_canvas_height - margin - 1);
    try context.lineTo(x_offset + margin, sub_canvas_height - margin - 1);
    try context.close();

    // Trapezoid
    const trapezoid_margin_top = 59;
    const trapezoid_margin_bottom = 33;
    const trapezoid_margin_y = 66;
    x_offset = sub_canvas_width * 2;
    try context.moveTo(x_offset + trapezoid_margin_top, 0 + trapezoid_margin_y);
    try context.lineTo(x_offset + sub_canvas_width - trapezoid_margin_top - 1, 0 + trapezoid_margin_y);
    try context.lineTo(x_offset + sub_canvas_width - trapezoid_margin_bottom - 1, sub_canvas_height - trapezoid_margin_y - 1);
    try context.lineTo(x_offset + trapezoid_margin_bottom, sub_canvas_height - trapezoid_margin_y - 1);
    try context.close();

    // Star
    margin = 13;
    const x_scale = 3;
    const y_scale = 5;
    x_offset = width / 6;
    const y_offset = sub_canvas_height;
    // With all 5 points numbered 1-5 clockwise, we draw odds first (1, 3, 5),
    // then evens (4, 2), with the close connecting 4 and 1.
    try context.moveTo(x_offset + sub_canvas_width / 2, y_offset + margin); // 1
    try context.lineTo(x_offset + sub_canvas_width - margin * x_scale - 1, y_offset + sub_canvas_height - margin - 1); // 3
    try context.lineTo(x_offset + margin, y_offset + margin * y_scale); // 5
    try context.lineTo(x_offset + sub_canvas_width - margin - 1, y_offset + margin * y_scale); // 2
    try context.lineTo(x_offset + margin * x_scale, y_offset + sub_canvas_height - margin - 1); // 4
    try context.close();

    // Bezier
    x_offset += sub_canvas_width;
    try context.moveTo(x_offset + 12, y_offset + 166);
    try context.curveTo(x_offset + 59, y_offset + 32, x_offset + 139, y_offset + 32, x_offset + 186, y_offset + 166);
    try context.close();

    try context.fill();

    return sfc;
}
