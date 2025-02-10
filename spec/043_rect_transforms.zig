// SPDX-License-Identifier: 0BSD
//   Copyright © 2024 Chris Marchesi

//! Case: Renders rectangles (fill and stroke) using transformation matrices.
const math = @import("std").math;
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "043_rect_transforms";

pub fn render(alloc: mem.Allocator, aa_mode: z2d.options.AntiAliasMode) !z2d.Surface {
    const width = 400;
    const height = 400;
    var sfc = try z2d.Surface.init(.image_surface_rgb, alloc, width, height);

    var context = try z2d.Context.init(alloc, &sfc);
    defer context.deinit();
    context.setSourceToPixel(.{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } });
    context.setAntiAliasingMode(aa_mode);
    context.setLineWidth(5);

    // Add a margin of (10, 10) by translation
    context.translate(10, 10);
    // first at 0, 0 rx = 50, ry=100
    _ = try rect(&context, 0, 0, 50, 100, true);
    try context.fill();

    // second as the first, but stroked, at 100, 0)
    _ = try rect(&context, 100, 0, 50, 100, true);
    try context.stroke();

    // as the second, but we capture the CTM to test stroke warping (at 200, 0)
    var saved_ctm = context.getTransformation();
    var saved_line_width = context.getLineWidth();
    try rect(&context, 200, 0, 50, 100, false);
    context.setLineWidth(lw: {
        var ux = saved_line_width;
        var uy = saved_line_width;
        try context.deviceToUserDistance(&ux, &uy);
        if (ux < uy) {
            break :lw uy;
        }
        break :lw ux;
    });
    try context.stroke();
    context.setTransformation(saved_ctm);
    context.setLineWidth(saved_line_width);

    // // as the third, but first rotate 45 degrees (at 300, 0)
    saved_ctm = context.getTransformation();
    saved_line_width = context.getLineWidth();
    context.rotate(math.pi / 4.0);
    try rect(&context, 300, 0, 50, 100, false);
    context.setLineWidth(lw: {
        var ux = saved_line_width;
        var uy = saved_line_width;
        try context.deviceToUserDistance(&ux, &uy);
        if (ux < uy) {
            break :lw uy;
        }
        break :lw ux;
    });
    try context.stroke();
    context.setTransformation(saved_ctm);
    context.setLineWidth(saved_line_width);

    return sfc;
}

fn rect(context: *z2d.Context, x: f64, y: f64, h: f64, w: f64, reset_ctm: bool) !void {
    const saved_ctm = context.getTransformation();
    context.resetPath();
    context.translate(x, y);
    context.scale(h, w);
    try context.moveTo(0, 0);
    try context.lineTo(1, 0);
    try context.lineTo(1, 1);
    try context.lineTo(0, 1);
    if (reset_ctm) context.setTransformation(saved_ctm);
    try context.closePath();
}
