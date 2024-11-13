// SPDX-License-Identifier: 0BSD
//   Copyright © 2024 Chris Marchesi

//! Case: Renders a stroked cross (used to validate correct join direction for
//! strokes when changing direction (clockwise -> counter-clockwise and vice versa).
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "034_stroke_cross";

pub fn render(alloc: mem.Allocator, aa_mode: z2d.options.AntiAliasMode) !z2d.Surface {
    const width = 250;
    const height = 250;
    var sfc = try z2d.Surface.init(.image_surface_rgb, alloc, width, height);

    var context = try z2d.Context.init(alloc, &sfc);
    defer context.deinit();
    context.setSource(.{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } });
    context.setAntiAliasingMode(aa_mode);
    context.setLineWidth(5);

    try context.moveTo(100, 50);
    try context.relLineTo(0, 50);
    try context.relLineTo(-50, 0);
    try context.relLineTo(0, 50);
    try context.relLineTo(50, 0);
    try context.relLineTo(0, 50);
    try context.relLineTo(50, 0);
    try context.relLineTo(0, -50);
    try context.relLineTo(50, 0);
    try context.relLineTo(0, -50);
    try context.relLineTo(-50, 0);
    try context.relLineTo(0, -50);
    try context.closePath();
    try context.stroke();

    return sfc;
}
