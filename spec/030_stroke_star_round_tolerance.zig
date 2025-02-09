// SPDX-License-Identifier: 0BSD
//   Copyright © 2024 Chris Marchesi

//! Case: Renders and strokes stars on a 900x300 surface with rounded corners,
//! and varying tolerance.
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "030_stroke_star_round_tolerance";

pub fn render(alloc: mem.Allocator, aa_mode: z2d.options.AntiAliasMode) !z2d.Surface {
    const width = 900;
    const height = 300;
    var sfc = try z2d.Surface.init(.image_surface_rgb, alloc, width, height);

    var context = try z2d.Context.init(alloc, &sfc);
    defer context.deinit();
    context.setSourceToPixel(.{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } });
    context.setAntiAliasingMode(aa_mode);
    context.setLineWidth(30);
    context.setLineJoinMode(.round);

    const margin = 20;
    const sub_canvas_width = 300;
    const x_scale = 3;
    const y_scale = 5;
    // With all 5 points numbered 1-5 clockwise, we draw odds first (1, 3, 5),
    // then evens (4, 2), with the close connecting 4 and 1.
    try context.moveTo(sub_canvas_width / 2, 0 + margin); // 1
    try context.lineTo(sub_canvas_width - margin * x_scale - 1, height - margin - 1); // 3
    try context.lineTo(0 + margin, 0 + margin * y_scale); // 5
    try context.lineTo(sub_canvas_width - margin - 1, 0 + margin * y_scale); // 2
    try context.lineTo(0 + margin * x_scale, height - margin - 1); // 4
    try context.closePath();
    try context.stroke();

    context.resetPath();
    context.setTolerance(3);
    var x_offset: f64 = 300;
    try context.moveTo(x_offset + sub_canvas_width / 2, 0 + margin); // 1
    try context.lineTo(x_offset + sub_canvas_width - margin * x_scale - 1, height - margin - 1); // 3
    try context.lineTo(x_offset + 0 + margin, 0 + margin * y_scale); // 5
    try context.lineTo(x_offset + sub_canvas_width - margin - 1, 0 + margin * y_scale); // 2
    try context.lineTo(x_offset + 0 + margin * x_scale, height - margin - 1); // 4
    try context.closePath();
    try context.stroke();

    context.resetPath();
    context.setTolerance(10);
    x_offset = 600;
    try context.moveTo(x_offset + sub_canvas_width / 2, 0 + margin); // 1
    try context.lineTo(x_offset + sub_canvas_width - margin * x_scale - 1, height - margin - 1); // 3
    try context.lineTo(x_offset + 0 + margin, 0 + margin * y_scale); // 5
    try context.lineTo(x_offset + sub_canvas_width - margin - 1, 0 + margin * y_scale); // 2
    try context.lineTo(x_offset + 0 + margin * x_scale, height - margin - 1); // 4
    try context.closePath();
    try context.stroke();

    return sfc;
}
