// SPDX-License-Identifier: 0BSD
//   Copyright © 2024 Chris Marchesi

//! Case: Ensures that certain extents don't get clipped on the larger
//! y-boundary.
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "039_stroke_paint_extent_dontclip";

pub fn render(alloc: mem.Allocator, aa_mode: z2d.options.AntiAliasMode) !z2d.Surface {
    const width = 50;
    const height = 80;
    const sfc = try z2d.Surface.init(.image_surface_rgb, alloc, width, height);

    var context: z2d.Context = .{
        .surface = sfc,
        .pattern = .{
            .opaque_pattern = .{
                .pixel = .{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } }, // White on black
            },
        },
        .line_width = 5,
        .anti_aliasing_mode = aa_mode,
    };

    var path = z2d.Path.init(alloc);
    defer path.deinit();

    try path.moveTo(40, 50);
    try path.lineTo(35, 60);
    try path.lineTo(30, 70);
    try path.lineTo(10, 50);

    try context.stroke(alloc, path);

    return sfc;
}
