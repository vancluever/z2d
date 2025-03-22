// SPDX-License-Identifier: 0BSD
//   Copyright © 2024 Chris Marchesi

//! Case: Renders and fills a diamond clipped on a 300x300 surface.
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "025_fill_diamond_clipped";

pub fn render(alloc: mem.Allocator, aa_mode: z2d.options.AntiAliasMode) !z2d.Surface {
    const width = 300;
    const height = 300;
    var sfc = try z2d.Surface.init(.image_surface_rgb, alloc, width, height);

    var context = z2d.Context.init(alloc, &sfc);
    defer context.deinit();
    context.setSourceToPixel(.{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } });
    context.setAntiAliasingMode(aa_mode);

    try context.moveTo(width / 2, 0 - height / 10);
    try context.lineTo(width + width / 10, height / 2);
    try context.lineTo(width / 2, height + height / 10);
    try context.lineTo(0 - width / 10, height / 2);
    try context.closePath();

    try context.fill();

    return sfc;
}
