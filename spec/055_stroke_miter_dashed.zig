// SPDX-License-Identifier: 0BSD
//   Copyright © 2024 Chris Marchesi

//! Case: Renders unclosed lines with miters. Dashed version.
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "055_stroke_miter_dashed";

pub fn render(alloc: mem.Allocator, aa_mode: z2d.options.AntiAliasMode) !z2d.Surface {
    const width = 240;
    const height = 260;
    var sfc = try z2d.Surface.init(.image_surface_rgb, alloc, width, height);

    var context = try z2d.Context.init(alloc, &sfc);
    defer context.deinit();
    context.setSource(.{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } });
    context.setAntiAliasingMode(aa_mode);
    // context.setLineWidth(6);
    context.setDashes(&.{ 15, 5 });

    try context.moveTo(10, 10);
    try context.lineTo(100, 20);
    try context.lineTo(110, 120);
    try context.lineTo(10, 110);
    try context.lineTo(20, 30);
    try context.lineTo(90, 40);
    try context.lineTo(95, 100);
    try context.lineTo(30, 95);
    try context.lineTo(30, 50);
    try context.lineTo(80, 50);
    try context.lineTo(75, 85);
    try context.lineTo(45, 80);
    try context.lineTo(50, 60);
    try context.lineTo(65, 70);

    ////////////////////
    const x_offset = 120;

    try context.moveTo(x_offset + 110, 10);
    try context.lineTo(x_offset + 20, 20);
    try context.lineTo(x_offset + 10, 120);
    try context.lineTo(x_offset + 110, 110);
    try context.lineTo(x_offset + 100, 30);
    try context.lineTo(x_offset + 30, 40);
    try context.lineTo(x_offset + 25, 100);
    try context.lineTo(x_offset + 90, 95);
    try context.lineTo(x_offset + 90, 50);
    try context.lineTo(x_offset + 40, 50);
    try context.lineTo(x_offset + 45, 85);
    try context.lineTo(x_offset + 75, 80);
    try context.lineTo(x_offset + 70, 60);
    try context.lineTo(x_offset + 55, 70);

    ////////////////////
    const y_offset = 130;

    try context.moveTo(10, y_offset + 120);
    try context.lineTo(100, y_offset + 110);
    try context.lineTo(110, y_offset + 10);
    try context.lineTo(10, y_offset + 20);
    try context.lineTo(20, y_offset + 100);
    try context.lineTo(90, y_offset + 90);
    try context.lineTo(95, y_offset + 30);
    try context.lineTo(30, y_offset + 35);
    try context.lineTo(30, y_offset + 80);
    try context.lineTo(80, y_offset + 80);
    try context.lineTo(75, y_offset + 45);
    try context.lineTo(45, y_offset + 50);
    try context.lineTo(50, y_offset + 70);
    try context.lineTo(65, y_offset + 60);

    ////////////////////

    try context.moveTo(x_offset + 110, y_offset + 120);
    try context.lineTo(x_offset + 20, y_offset + 110);
    try context.lineTo(x_offset + 10, y_offset + 10);
    try context.lineTo(x_offset + 110, y_offset + 20);
    try context.lineTo(x_offset + 100, y_offset + 100);
    try context.lineTo(x_offset + 30, y_offset + 90);
    try context.lineTo(x_offset + 25, y_offset + 30);
    try context.lineTo(x_offset + 90, y_offset + 35);
    try context.lineTo(x_offset + 90, y_offset + 80);
    try context.lineTo(x_offset + 40, y_offset + 80);
    try context.lineTo(x_offset + 45, y_offset + 45);
    try context.lineTo(x_offset + 75, y_offset + 50);
    try context.lineTo(x_offset + 70, y_offset + 70);
    try context.lineTo(x_offset + 55, y_offset + 60);

    try context.stroke();

    return sfc;
}
