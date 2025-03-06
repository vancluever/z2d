// SPDX-License-Identifier: 0BSD
//   Copyright © 2024 Chris Marchesi

//! Case: Renders and strokes a star on a 300x300 surface, with a gradient as
//! the color source.
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "059_stroke_star_gradient";

pub fn render(alloc: mem.Allocator, aa_mode: z2d.options.AntiAliasMode) !z2d.Surface {
    const width = 300;
    const height = 300;
    var sfc = try z2d.Surface.init(.image_surface_rgb, alloc, width, height);

    var context = try z2d.Context.init(alloc, &sfc);
    defer context.deinit();
    context.setAntiAliasingMode(aa_mode);
    context.setLineWidth(10);
    context.setLineJoinMode(.round);

    const margin = 20;
    const x_scale = 3;
    const y_scale = 5;

    var gradient = z2d.Gradient.init(.{ .type = .{ .linear = .{
        .x0 = 0 + margin * 3,
        .y0 = height / 2,
        .x1 = width - margin * 3,
        .y1 = height / 2,
    } } });
    defer gradient.deinit(alloc);
    try gradient.addStop(alloc, 0, .{ .rgb = .{ 1, 0, 0 } });
    try gradient.addStop(alloc, 0.5, .{ .rgb = .{ 0, 1, 0 } });
    try gradient.addStop(alloc, 1, .{ .rgb = .{ 0, 0, 1 } });
    context.setSource(gradient.asPattern());

    // With all 5 points numbered 1-5 clockwise, we draw odds first (1, 3, 5),
    // then evens (4, 2), with the close connecting 4 and 1.
    try context.moveTo(width / 2, 0 + margin); // 1
    try context.lineTo(width - margin * x_scale - 1, height - margin - 1); // 3
    try context.lineTo(0 + margin, 0 + margin * y_scale); // 5
    try context.lineTo(width - margin - 1, 0 + margin * y_scale); // 2
    try context.lineTo(0 + margin * x_scale, height - margin - 1); // 4
    try context.closePath();

    try context.stroke();

    return sfc;
}
