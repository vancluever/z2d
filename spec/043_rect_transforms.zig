// SPDX-License-Identifier: 0BSD
//   Copyright © 2024 Chris Marchesi

//! Case: Renders rectangles (fill and stroke) using transformation matrices.
const debug = @import("std").debug;
const math = @import("std").math;
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "043_rect_transforms";

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
    // first at 0, 0 rx = 50, ry=100
    _ = try rect(&path, 0, 0, 50, 100);
    try context.fill(alloc, path);

    // second as the first, but stroked, at 100, 0)
    _ = try rect(&path, 100, 0, 50, 100);
    try context.stroke(alloc, path);

    // as the second, but we capture the CTM to test stroke warping (at 200, 0)
    var saved_ctm = context.transformation;
    var saved_line_width = context.line_width;
    context.transformation = try rect(&path, 200, 0, 50, 100);
    context.line_width = lw: {
        var ux = saved_line_width;
        var uy = saved_line_width;
        try context.transformation.deviceToUserDistance(&ux, &uy);
        if (ux < uy) {
            break :lw uy;
        }
        break :lw ux;
    };
    try context.stroke(alloc, path);
    context.transformation = saved_ctm;
    context.line_width = saved_line_width;

    // // as the third, but first rotate 45 degrees (at 300, 0)
    const saved_path_ctm = path.transformation;
    saved_ctm = context.transformation;
    saved_line_width = context.line_width;
    path.transformation = path.transformation.rotate(math.pi / 4.0);
    context.transformation = try rect(&path, 300, 0, 50, 100);
    context.line_width = lw: {
        var ux = saved_line_width;
        var uy = saved_line_width;
        try context.transformation.deviceToUserDistance(&ux, &uy);
        if (ux < uy) {
            break :lw uy;
        }
        break :lw ux;
    };
    try context.stroke(alloc, path);
    path.transformation = saved_path_ctm;
    context.transformation = saved_ctm;
    context.line_width = saved_line_width;

    return sfc;
}

fn rect(path: *z2d.Path, x: f64, y: f64, h: f64, w: f64) !z2d.Transformation {
    const saved_ctm = path.transformation;
    path.reset();
    path.transformation = path.transformation
        .translate(x, y)
        .scale(h, w);
    try path.moveTo(0, 0);
    try path.lineTo(1, 0);
    try path.lineTo(1, 1);
    try path.lineTo(0, 1);
    const effective_ctm = path.transformation;
    path.transformation = saved_ctm;
    try path.close();
    return effective_ctm;
}
