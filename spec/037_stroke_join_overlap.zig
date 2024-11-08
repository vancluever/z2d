// SPDX-License-Identifier: 0BSD
//   Copyright © 2024 Chris Marchesi

//! Case: Draws overlapping strokes in different directions to test that joins
//! with extremely acute angles overlap properly.
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "037_stroke_join_overlap";

pub fn render(alloc: mem.Allocator, aa_mode: z2d.options.AntiAliasMode) !z2d.Surface {
    const width = 200;
    const height = 200;
    var sfc = try z2d.Surface.init(.image_surface_rgb, alloc, width, height);

    var context = try z2d.Context.init(alloc, &sfc);
    defer context.deinit();
    context.setSource(.{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } });
    context.setAntiAliasingMode(aa_mode);
    context.setLineWidth(5);
    context.setMiterLimit(4);

    try context.moveTo(10, 10);
    try context.lineTo(50, 90);
    try context.lineTo(35, 50);

    try context.moveTo(190, 10);
    try context.lineTo(150, 90);
    try context.lineTo(165, 50);

    try context.moveTo(10, 190);
    try context.lineTo(50, 110);
    try context.lineTo(35, 150);

    try context.moveTo(190, 190);
    try context.lineTo(150, 110);
    try context.lineTo(165, 150);

    try context.stroke();

    return sfc;
}
