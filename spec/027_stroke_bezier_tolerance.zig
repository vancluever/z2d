// SPDX-License-Identifier: 0BSD
//   Copyright © 2024 Chris Marchesi

//! Case: Renders and strokes stacked beziers of varying thickness on a 300x300
//! surface, at varying levels of error tolerance.
//!
//! The beziers are not closed.
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "027_bezier_tolerance";

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
    context.line_width = 5;

    try path.moveTo(alloc, 19, 149);
    try path.curveTo(alloc, 89, 0, 209, 0, 279, 149);
    try context.stroke(alloc, path);

    context.tolerance = 3;
    path.reset();
    try path.moveTo(alloc, 19, 199);
    try path.curveTo(alloc, 89, 24, 209, 24, 279, 199);
    try context.stroke(alloc, path);

    context.tolerance = 10;
    path.reset();
    try path.moveTo(alloc, 19, 249);
    try path.curveTo(alloc, 89, 49, 209, 49, 279, 249);
    try context.stroke(alloc, path);

    return sfc;
}
