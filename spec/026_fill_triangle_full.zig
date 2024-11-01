// SPDX-License-Identifier: 0BSD
//   Copyright © 2024 Chris Marchesi

//! Case: Renders and fills a triangle on a 300x300 surface, extended to the
//! full canvas.
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "026_fill_triangle_full";

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

    try path.moveTo(alloc, 0, 0);
    try path.lineTo(alloc, width, 0);
    try path.lineTo(alloc, width / 2, height);
    try path.close(alloc);

    try context.fill(alloc, path);

    return sfc;
}
