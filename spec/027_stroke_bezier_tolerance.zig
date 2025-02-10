// SPDX-License-Identifier: 0BSD
//   Copyright © 2024 Chris Marchesi

//! Case: Renders and strokes stacked beziers of varying thickness on a 300x300
//! surface, at varying levels of error tolerance.
//!
//! The beziers are not closed.
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "027_bezier_tolerance";

pub fn render(alloc: mem.Allocator, aa_mode: z2d.options.AntiAliasMode) !z2d.Surface {
    const width = 300;
    const height = 300;
    var sfc = try z2d.Surface.init(.image_surface_rgb, alloc, width, height);

    var context = try z2d.Context.init(alloc, &sfc);
    defer context.deinit();
    context.setSourceToPixel(.{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } });
    context.setAntiAliasingMode(aa_mode);
    context.setLineWidth(5);

    try context.moveTo(19, 149);
    try context.curveTo(89, 0, 209, 0, 279, 149);
    try context.stroke();

    context.setTolerance(3);
    context.resetPath();
    try context.moveTo(19, 199);
    try context.curveTo(89, 24, 209, 24, 279, 199);
    try context.stroke();

    context.setTolerance(10);
    context.resetPath();
    try context.moveTo(19, 249);
    try context.curveTo(89, 49, 209, 49, 279, 249);
    try context.stroke();

    return sfc;
}
