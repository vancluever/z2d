// SPDX-License-Identifier: 0BSD
//   Copyright © 2024 Chris Marchesi

//! Case: Renders and fills a star on a 300x300 surface.
//!
//! NOTE: This star explicitly fills with non-zero rule, so it's expected for
//! there to NOT be a gap in the middle.
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "016_fill_star_non_zero";

pub fn render(alloc: mem.Allocator, aa_mode: z2d.options.AntiAliasMode) !z2d.Surface {
    const width = 300;
    const height = 300;
    var sfc = try z2d.Surface.init(.image_surface_rgb, alloc, width, height);

    var context = try z2d.Context.init(alloc, &sfc);
    defer context.deinit();
    context.setSource(.{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } });
    context.setAntiAliasingMode(aa_mode);
    context.setFillRule(.non_zero);

    const margin = 20;
    const x_scale = 3;
    const y_scale = 5;
    // With all 5 points numbered 1-5 clockwise, we draw odds first (1, 3, 5),
    // then evens (4, 2), with the close connecting 4 and 1.
    try context.moveTo(width / 2, 0 + margin); // 1
    try context.lineTo(width - margin * x_scale - 1, height - margin - 1); // 3
    try context.lineTo(0 + margin, 0 + margin * y_scale); // 5
    try context.lineTo(width - margin - 1, 0 + margin * y_scale); // 2
    try context.lineTo(0 + margin * x_scale, height - margin - 1); // 4
    try context.close();

    try context.fill();

    return sfc;
}
