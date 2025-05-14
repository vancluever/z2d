// SPDX-License-Identifier: 0BSD
//   Copyright © 2024-2025 Chris Marchesi

//! Case: Renders and strokes a square on a 300x300 surface, but has a lineTo
//! back to the initial point before the close. Correct rendering of the square
//! asserts that this special case is properly handled.
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "073_stroke_sameclose";

pub fn render(alloc: mem.Allocator, aa_mode: z2d.options.AntiAliasMode) !z2d.Surface {
    const width = 300;
    const height = 300;
    var sfc = try z2d.Surface.init(.image_surface_rgb, alloc, width, height);

    var context = z2d.Context.init(alloc, &sfc);
    defer context.deinit();
    context.setSourceToPixel(.{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } });
    context.setAntiAliasingMode(aa_mode);

    const margin = 50;
    try context.moveTo(0 + margin, 0 + margin);
    try context.lineTo(width - margin - 1, 0 + margin);
    try context.lineTo(width - margin - 1, height - margin - 1);
    try context.lineTo(0 + margin, height - margin - 1);
    try context.lineTo(0 + margin, 0 + margin);
    try context.closePath();

    try context.stroke();

    return sfc;
}
