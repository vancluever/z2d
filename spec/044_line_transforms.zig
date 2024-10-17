// SPDX-License-Identifier: 0BSD
//   Copyright © 2024 Chris Marchesi

//! Case: Renders lines at various angles, stretched using transformations and
//! square/round caps.
//!
//! TODO: After iteration #4 here we fall into degenerate cases that we are
//! currently blocking in the rasterizing process for stroking, so they will
//! not appear as they would normally in Cairo et al. This is something we need
//! to fix eventually. With that said, these differences currently seem to be
//! minimal, mostly having to do with restricting cap and join at extremely
//! small line widths.
const math = @import("std").math;
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "044_line_transforms";

pub fn render(alloc: mem.Allocator, aa_mode: z2d.options.AntiAliasMode) !z2d.Surface {
    const width = 700;
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
        .line_width = 10,
    };

    for (0..7) |i| try line(alloc, &context, @floatFromInt(i), false, false);
    for (0..7) |i| try line(alloc, &context, @floatFromInt(i), true, false);
    for (0..7) |i| try line(alloc, &context, @floatFromInt(i), false, true);
    for (0..7) |i| try line(alloc, &context, @floatFromInt(i), true, true);

    return sfc;
}

fn line(alloc: mem.Allocator, context: *z2d.Context, i: f64, reverse: bool, round: bool) !void {
    const saved_context_ctm = context.transformation;
    defer context.transformation = saved_context_ctm;

    const saved_line_width = context.line_width;
    defer context.line_width = saved_line_width;

    const saved_pattern = context.pattern;
    defer context.pattern = saved_pattern;

    context.line_cap_mode = if (round) .round else .square;
    defer context.line_cap_mode = .butt;

    const y_offset = yoff: {
        var y: f64 = 50;
        if (reverse) y += 100;
        if (round) y += 200;
        break :yoff y;
    };

    context.transformation = if (reverse)
        context.transformation
            .translate(i * 100 + 25, y_offset + 25 * @sin(math.pi / 6.0 * i))
            .rotate(-math.pi / 6.0 * i)
            .scale(2, 1)
    else
        context.transformation
            .translate(i * 100 + 25, y_offset - 25 * @sin(math.pi / 6.0 * i))
            .rotate(math.pi / 6.0 * i)
            .scale(2, 1);
    var path = z2d.Path.init(alloc);
    defer path.deinit();
    path.transformation = context.transformation;
    if (reverse) {
        try path.moveTo(0, 0);
        try path.lineTo(25, 0);
    } else {
        try path.moveTo(25, 0);
        try path.lineTo(0, 0);
    }
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

    // Draw a hairline in red to help validate/measure
    context.pattern.opaque_pattern.pixel = .{ .rgb = .{ .r = 0xF3, .g = 0x00, .b = 0x00 } }; // Red
    context.line_width = 1;

    try context.stroke(alloc, path);
}
