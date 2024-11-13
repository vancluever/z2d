// SPDX-License-Identifier: 0BSD
//   Copyright © 2024 Chris Marchesi

//! Case: Asserts correctness in colinear stroke operations.
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "036_stroke_colinear";

pub fn render(alloc: mem.Allocator, aa_mode: z2d.options.AntiAliasMode) !z2d.Surface {
    const width = 100;
    const height = 240;
    var sfc = try z2d.Surface.init(.image_surface_rgb, alloc, width, height);

    var context = try z2d.Context.init(alloc, &sfc);
    defer context.deinit();
    context.setSource(.{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } });
    context.setAntiAliasingMode(aa_mode);
    context.setLineWidth(4);

    // clockwise
    try context.moveTo(40, 50);
    try context.lineTo(35, 60);
    try context.lineTo(30, 70);
    try context.lineTo(10, 50);

    // counter-clockwise
    try context.moveTo(10, 10);
    try context.lineTo(20, 20);
    try context.lineTo(30, 30);
    try context.lineTo(40, 10);

    // clockwise, closed
    try context.moveTo(90, 50);
    try context.lineTo(85, 60);
    try context.lineTo(80, 70);
    try context.lineTo(60, 50);
    try context.closePath();

    // counter-clockwise, closed
    try context.moveTo(60, 10);
    try context.lineTo(70, 20);
    try context.lineTo(80, 30);
    try context.lineTo(90, 10);
    try context.closePath();

    // single line, UL -> DR
    try context.moveTo(10, 90);
    try context.lineTo(25, 100);
    try context.lineTo(40, 110);

    // single line, DL -> UR
    try context.moveTo(10, 150);
    try context.lineTo(25, 140);
    try context.lineTo(40, 130);

    // single line, UR -> DL
    try context.moveTo(90, 90);
    try context.lineTo(75, 100);
    try context.lineTo(60, 110);

    // single line, DR -> UL
    try context.moveTo(90, 150);
    try context.lineTo(75, 140);
    try context.lineTo(60, 130);

    // switchback
    try context.moveTo(10, 170);
    try context.lineTo(30, 190);
    try context.lineTo(20, 180);
    try context.lineTo(40, 170);

    // switchback, reflected on x-axis
    try context.moveTo(90, 170);
    try context.lineTo(70, 190);
    try context.lineTo(80, 180);
    try context.lineTo(60, 170);

    // clockwise after start
    try context.moveTo(40, 210);
    try context.lineTo(30, 230);
    try context.lineTo(20, 220);
    try context.lineTo(10, 210);

    // counter-clockwise after start
    try context.moveTo(60, 210);
    try context.lineTo(70, 230);
    try context.lineTo(80, 220);
    try context.lineTo(90, 210);

    try context.stroke();

    return sfc;
}
