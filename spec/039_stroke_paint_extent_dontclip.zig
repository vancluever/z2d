// SPDX-License-Identifier: 0BSD
//   Copyright © 2024 Chris Marchesi

//! Case: Ensures that certain extents don't get clipped on the larger
//! y-boundary.
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "039_stroke_paint_extent_dontclip";

pub fn render(alloc: mem.Allocator, aa_mode: z2d.options.AntiAliasMode) !z2d.Surface {
    const width = 50;
    const height = 80;
    var sfc = try z2d.Surface.init(.image_surface_rgb, alloc, width, height);

    var context = try z2d.Context.init(alloc, &sfc);
    defer context.deinit();
    context.setSource(.{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } });
    context.setAntiAliasingMode(aa_mode);
    context.setLineWidth(5);

    try context.moveTo(40, 50);
    try context.lineTo(35, 60);
    try context.lineTo(30, 70);
    try context.lineTo(10, 50);

    try context.stroke();

    return sfc;
}
