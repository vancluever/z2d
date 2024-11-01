// SPDX-License-Identifier: 0BSD
//   Copyright © 2024 Chris Marchesi

//! Case: Renders and fills a diamond clipped on a 300x300 surface.
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "025_fill_diamond_clipped";

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

    try path.moveTo(alloc, width / 2, 0 - height / 10);
    try path.lineTo(alloc, width + width / 10, height / 2);
    try path.lineTo(alloc, width / 2, height + height / 10);
    try path.lineTo(alloc, 0 - width / 10, height / 2);
    try path.close(alloc);

    try context.fill(alloc, path);

    return sfc;
}
