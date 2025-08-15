// SPDX-License-Identifier: 0BSD
//   Copyright © 2024-2025 Chris Marchesi

//! Case: Test degenerate line_to cases for fill. These produce edges, but they
//! should be discarded during rasterization or otherwise create odd images,
//! but they should succeed.
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "079_fill_degenerate_lineto";

pub fn render(alloc: mem.Allocator, aa_mode: z2d.options.AntiAliasMode) !z2d.Surface {
    const width = 100;
    const height = 200;
    var sfc = try z2d.Surface.init(.image_surface_rgb, alloc, width, height);

    var context = z2d.Context.init(alloc, &sfc);
    defer context.deinit();
    context.setAntiAliasingMode(aa_mode);
    context.setSourceToPixel(.{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } });

    // Should produce nothing
    try context.moveTo(180, 180);
    try context.lineTo(190, 190);
    try context.closePath();
    try context.fill();

    // Should produce a complete square on the left, nothing on the right
    context.resetPath();
    try context.moveTo(10, 10);
    try context.lineTo(20, 10);
    try context.lineTo(20, 20);
    try context.lineTo(10, 20);
    try context.closePath();
    try context.moveTo(50, 10);
    try context.lineTo(70, 20);
    try context.closePath();
    try context.fill();

    // Should produce a broken polygon as the discarded odd edge will be part
    // of the square on the right (and be clipped to the square's y)
    context.resetPath();
    try context.moveTo(10, 50);
    try context.lineTo(30, 70);
    try context.closePath();
    try context.moveTo(50, 50);
    try context.lineTo(60, 50);
    try context.lineTo(60, 60);
    try context.lineTo(50, 60);
    try context.closePath();
    try context.fill();

    // As above, but the bad edge is off-canvas on the left
    context.resetPath();
    try context.moveTo(-30, 80);
    try context.lineTo(-10, 100);
    try context.closePath();
    try context.moveTo(50, 80);
    try context.lineTo(60, 80);
    try context.lineTo(60, 90);
    try context.lineTo(50, 90);
    try context.closePath();
    try context.fill();

    // As above, but the square is off-canvas on the right
    context.resetPath();
    try context.moveTo(10, 110);
    try context.lineTo(30, 130);
    try context.closePath();
    try context.moveTo(150, 110);
    try context.lineTo(160, 110);
    try context.lineTo(160, 120);
    try context.lineTo(150, 120);
    try context.closePath();
    try context.fill();

    // As the first, but the bad edge is off the canvas on the right
    context.resetPath();
    try context.moveTo(10, 140);
    try context.lineTo(20, 140);
    try context.lineTo(20, 150);
    try context.lineTo(10, 150);
    try context.closePath();
    try context.moveTo(50, 140);
    try context.lineTo(70, 150);
    try context.closePath();
    try context.fill();

    return sfc;
}
