// SPDX-License-Identifier: 0BSD
//   Copyright © 2024 Chris Marchesi

//! Case: Renders and fills quadratic beziers and degenerate curves (where one
//! of the control points is the same as the start or end point) on a 300x300
//! surface.
//!
//! This is a validation test against degenerate parts existing in the bezier,
//! since some of our control points are the same.
//!
//! Note that odd and even curves as defined below are shaped differently. This
//! is due to the fact that the first 2 sets of (x, y) co-ordinates that are
//! given to curveTo define the control points, and the current point (e.g.,
//! the one that you'd set with moveTo) and the final point are technically the
//! start and end points. Thus, to get a proper quadratic to what you'd expect,
//! you need the *control* points (so (x1, y1), (x2, y2)) to be equal.
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "031_fill_quad_bezier";

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

    try path.moveTo(alloc, 20, 130);
    try path.curveTo(alloc, 20, 130, 20, 20, 130, 20);
    try path.close(alloc);

    try path.moveTo(alloc, 170, 20);
    try path.curveTo(alloc, 280, 20, 280, 20, 280, 130);
    try path.close(alloc);

    try path.moveTo(alloc, 280, 170);
    try path.curveTo(alloc, 280, 280, 170, 280, 170, 280);
    try path.close(alloc);

    try path.moveTo(alloc, 130, 280);
    try path.curveTo(alloc, 20, 280, 20, 280, 20, 170);
    try path.close(alloc);

    try context.fill(alloc, path);

    return sfc;
}
