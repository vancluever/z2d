// SPDX-License-Identifier: 0BSD
//   Copyright © 2024 Chris Marchesi

//! Case: ensures proper alignment of a line spanning the whole box diagonally.
//! The line should be symmetrical on both the upper left and bottom right
//! corners of the box.
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "040_stroke_corner_symmetrical";

pub fn render(alloc: mem.Allocator, aa_mode: z2d.options.AntiAliasMode) !z2d.Surface {
    const width = 18;
    const height = 36;
    var sfc = try z2d.Surface.init(.image_surface_rgb, alloc, width, height);

    var context = try z2d.Context.init(alloc, &sfc);
    defer context.deinit();
    context.setSource(.{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } });
    context.setAntiAliasingMode(aa_mode);

    try context.moveTo(0, 0);
    try context.lineTo(width, height);

    try context.stroke();

    return sfc;
}
