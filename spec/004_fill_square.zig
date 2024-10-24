// SPDX-License-Identifier: 0BSD
//   Copyright © 2024 Chris Marchesi

//! Case: Renders and fills a square on a 300x300 surface.
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "004_fill_square";

pub fn render(alloc: mem.Allocator, aa_mode: z2d.options.AntiAliasMode) !z2d.Surface {
    const width = 300;
    const height = 300;
    const sfc = try z2d.Surface.init(.image_surface_rgb, alloc, width, height);

    var context: z2d.Context = .{
        .surface = sfc,
        .pattern = .{
            .opaque_pattern = .{
                .pixel = .{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } }, // White on black
            },
        },
        .anti_aliasing_mode = aa_mode,
    };

    var path = z2d.Path.init(alloc);
    defer path.deinit();

    const margin = 50;
    try path.moveTo(0 + margin, 0 + margin);
    try path.lineTo(width - margin - 1, 0 + margin);
    try path.lineTo(width - margin - 1, height - margin - 1);
    try path.lineTo(0 + margin, height - margin - 1);
    try path.close();

    try context.fill(alloc, path);

    return sfc;
}
