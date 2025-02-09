// SPDX-License-Identifier: 0BSD
//   Copyright © 2024 Chris Marchesi

//! Case: Renders multiple lines, round-capped at varying levels of tolerance.
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "029_stroke_lines_round_caps_tolerance";

pub fn render(alloc: mem.Allocator, aa_mode: z2d.options.AntiAliasMode) !z2d.Surface {
    const width = 300;
    const height = 300;
    var sfc = try z2d.Surface.init(.image_surface_rgb, alloc, width, height);

    var context = try z2d.Context.init(alloc, &sfc);
    defer context.deinit();
    context.setSourceToPixel(.{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } });
    context.setAntiAliasingMode(aa_mode);
    context.setLineCapMode(.round);
    context.setLineJoinMode(.round);
    context.setLineWidth(30);

    try context.moveTo(30, 50);
    try context.lineTo(270, 50);
    try context.stroke();

    context.setTolerance(3);
    context.resetPath();
    try context.moveTo(30, 150);
    try context.lineTo(270, 150);
    try context.stroke();

    context.setTolerance(10);
    context.resetPath();
    try context.moveTo(30, 250);
    try context.lineTo(270, 250);
    try context.stroke();

    return sfc;
}
