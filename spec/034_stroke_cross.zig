// SPDX-License-Identifier: 0BSD
//   Copyright © 2024 Chris Marchesi

//! Case: Renders a stroked cross (used to validate correct join direction for
//! strokes when changing direction (clockwise -> counter-clockwise and vice versa).
const debug = @import("std").debug;
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "034_stroke_cross";

pub fn render(alloc: mem.Allocator, aa_mode: z2d.options.AntiAliasMode) !z2d.Surface {
    const width = 250;
    const height = 250;
    const sfc = try z2d.Surface.init(.image_surface_rgb, alloc, width, height);

    var context: z2d.Context = .{
        .surface = sfc,
        .pattern = .{
            .opaque_pattern = .{
                .pixel = .{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } }, // White on black
            },
        },
        .anti_aliasing_mode = aa_mode,
        .line_width = 5,
    };

    var path = z2d.Path.init(alloc);
    defer path.deinit();

    try path.moveTo(100, 50);
    try path.relLineTo(0, 50);
    try path.relLineTo(-50, 0);
    try path.relLineTo(0, 50);
    try path.relLineTo(50, 0);
    try path.relLineTo(0, 50);
    try path.relLineTo(50, 0);
    try path.relLineTo(0, -50);
    try path.relLineTo(50, 0);
    try path.relLineTo(0, -50);
    try path.relLineTo(-50, 0);
    try path.relLineTo(0, -50);
    try path.close();
    try context.stroke(alloc, path);

    return sfc;
}
