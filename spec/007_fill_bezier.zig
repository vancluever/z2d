// SPDX-License-Identifier: 0BSD
//   Copyright © 2024 Chris Marchesi

//! Case: Renders and fills a bezier curve on a 300x300 surface.
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "007_fill_bezier";

pub fn render(alloc: mem.Allocator, aa_mode: z2d.options.AntiAliasMode) !z2d.Surface {
    const width = 300;
    const height = 300;
    var sfc = try z2d.Surface.init(.image_surface_rgb, alloc, width, height);

    var context = try z2d.Context.init(alloc, &sfc);
    defer context.deinit();
    context.setSource(.{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } });
    context.setAntiAliasingMode(aa_mode);

    try context.moveTo(19, 249);
    try context.curveTo(89, 49, 209, 49, 279, 249);
    try context.closePath();

    try context.fill();

    return sfc;
}
