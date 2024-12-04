// SPDX-License-Identifier: 0BSD
//   Copyright © 2024 Chris Marchesi

//! Case: Renders and fills a triangle on a 300x300 surface using alpha8 for
//! grayscale.
//!
//! This is similar to the 003_fill_triangle.zig, but uses alpha8 as its source
//! versus RGB. Also renders a gray triangle at half alpha to test optimized
//! composition path.
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "051_fill_triangle_alpha1_gray";

pub fn render(alloc: mem.Allocator, aa_mode: z2d.options.AntiAliasMode) !z2d.Surface {
    const width = 300;
    const height = 300;
    var sfc = try z2d.Surface.init(
        .image_surface_alpha1,
        alloc,
        width,
        height,
    );

    var context = try z2d.Context.init(alloc, &sfc);
    defer context.deinit();
    context.setSource(.{ .alpha1 = .{ .a = 1 } });
    context.setAntiAliasingMode(aa_mode);

    const margin = 10;
    try context.moveTo(0 + margin, 0 + margin);
    try context.lineTo(width - margin - 1, 0 + margin);
    try context.lineTo(width / 2 - 1, height - margin - 1);
    try context.closePath();

    try context.fill();

    return sfc;
}
