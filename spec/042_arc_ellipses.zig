// SPDX-License-Identifier: 0BSD
//   Copyright © 2024 Chris Marchesi

//! Case: Renders ellipses (fill and stroke) using arc commands and
//! transformation matrices.
const debug = @import("std").debug;
const math = @import("std").math;
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "042_arc_ellipses";

pub fn render(alloc: mem.Allocator, aa_mode: z2d.options.AntiAliasMode) !z2d.Surface {
    const width = 400;
    const height = 400;
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
    // Add a margin of (10, 10) by translation
    path.transformation = path.transformation.translate(10, 10);
    // first ellipse at 0, 0 rx = 50, ry=100
    try ellipse(&path, 0, 0, 50, 100);
    try context.fill(alloc, path);

    // second as the first, but stroked, at 100, 0)
    try ellipse(&path, 100, 0, 50, 100);
    try context.stroke(alloc, path);

    return sfc;
}

fn ellipse(path: *z2d.Path, x: f64, y: f64, rx: f64, ry: f64) !void {
    const saved_ctm = path.transformation;
    path.reset();
    path.transformation = path.transformation
        .translate(x + rx / 2, y + ry / 2)
        .scale(rx / 2, ry / 2);
    try path.arc(0, 0, 1, 0, 2 * math.pi, false, null);
    path.transformation = saved_ctm;
    try path.close();
}
