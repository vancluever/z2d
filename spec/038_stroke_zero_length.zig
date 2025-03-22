// SPDX-License-Identifier: 0BSD
//   Copyright © 2024 Chris Marchesi

//! Case: Renders and fills a triangle on a 300x300 surface.
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "038_stroke_zero_length";

pub fn render(alloc: mem.Allocator, aa_mode: z2d.options.AntiAliasMode) !z2d.Surface {
    const width = 60;
    const height = 60;
    var sfc = try z2d.Surface.init(.image_surface_rgb, alloc, width, height);

    var context = z2d.Context.init(alloc, &sfc);
    defer context.deinit();
    context.setSourceToPixel(.{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } });
    context.setAntiAliasingMode(aa_mode);
    context.setLineWidth(10);
    context.setLineCapMode(.round);

    try context.moveTo(10, 10);
    try context.closePath();

    try context.moveTo(30, 30);
    try context.lineTo(30, 30);
    try context.lineTo(30, 30);
    try context.closePath();

    // This should not draw anything
    try context.moveTo(50, 50);

    try context.stroke();

    return sfc;
}
