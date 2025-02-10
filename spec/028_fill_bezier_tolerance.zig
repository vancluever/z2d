// SPDX-License-Identifier: 0BSD
//   Copyright © 2024 Chris Marchesi

//! Case: Renders and fills bezier curves on a 900x300 surface at varying
//! levels of error tolerance.
const debug = @import("std").debug;
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "028_fill_bezier_tolerance";

pub fn render(alloc: mem.Allocator, aa_mode: z2d.options.AntiAliasMode) !z2d.Surface {
    const width = 900;
    const height = 300;
    var sfc = try z2d.Surface.init(.image_surface_rgb, alloc, width, height);

    var context = try z2d.Context.init(alloc, &sfc);
    defer context.deinit();
    context.setSourceToPixel(.{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } });
    context.setAntiAliasingMode(aa_mode);
    context.setLineWidth(5);

    try context.moveTo(19, 224);
    try context.curveTo(89, 49, 209, 49, 279, 224);
    try context.closePath();
    try context.fill();

    context.setTolerance(3);
    context.resetPath();
    try context.moveTo(319, 224);
    try context.curveTo(389, 49, 509, 49, 579, 224);
    try context.closePath();
    try context.fill();

    context.setTolerance(10);
    context.resetPath();
    try context.moveTo(619, 224);
    try context.curveTo(689, 49, 809, 49, 879, 224);
    try context.closePath();
    try context.fill();

    return sfc;
}
