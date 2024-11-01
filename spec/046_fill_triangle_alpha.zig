// SPDX-License-Identifier: 0BSD
//   Copyright © 2024 Chris Marchesi

//! Case: Renders and fills a triangle on a 300x300 surface.
//!
//! This is similar to the 003_fill_triangle.zig, but uses alpha8 as its source
//! versus RGB.
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "046_fill_triangle_alpha";

pub fn render(alloc: mem.Allocator, aa_mode: z2d.options.AntiAliasMode) !z2d.Surface {
    const width = 300;
    const height = 300;
    const sfc = try z2d.Surface.initPixel(
        .{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } }, // White so that srcOver shows up correctly
        alloc,
        width,
        height,
    );

    var context: z2d.Context = .{
        .surface = sfc,
        .pattern = .{
            .opaque_pattern = .{
                .pixel = .{ .alpha8 = .{ .a = 255 } },
            },
        },
        .anti_aliasing_mode = aa_mode,
    };

    var path = try z2d.Path.initCapacity(alloc, 0);
    defer path.deinit(alloc);

    const margin = 10;
    try path.moveTo(alloc, 0 + margin, 0 + margin);
    try path.lineTo(alloc, width - margin - 1, 0 + margin);
    try path.lineTo(alloc, width / 2 - 1, height - margin - 1);
    try path.close(alloc);

    try context.fill(alloc, path);

    return sfc;
}
