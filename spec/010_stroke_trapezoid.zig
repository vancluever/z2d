// SPDX-License-Identifier: 0BSD
//   Copyright © 2024 Chris Marchesi

//! Case: Renders and strokes a trapezoid on a 300x300 surface.
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "010_stroke_trapezoid";

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

    const margin_top = 89;
    const margin_bottom = 50;
    const margin_y = 100;
    try path.moveTo(0 + margin_top, 0 + margin_y);
    try path.lineTo(width - margin_top - 1, 0 + margin_y);
    try path.lineTo(width - margin_bottom - 1, height - margin_y - 1);
    try path.lineTo(0 + margin_bottom, height - margin_y - 1);
    try path.close();

    try context.stroke(alloc, path);

    return sfc;
}
