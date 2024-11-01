// SPDX-License-Identifier: 0BSD
//   Copyright © 2024 Chris Marchesi

//! Case: Renders and fills a bezier curve on a 300x300 surface.
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "007_fill_bezier";

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

    var path = try z2d.Path.initCapacity(alloc, 0);
    defer path.deinit(alloc);

    try path.moveTo(alloc, 19, 249);
    try path.curveTo(alloc, 89, 49, 209, 49, 279, 249);
    try path.close(alloc);

    try context.fill(alloc, path);

    return sfc;
}
