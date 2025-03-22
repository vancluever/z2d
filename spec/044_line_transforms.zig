// SPDX-License-Identifier: 0BSD
//   Copyright © 2024-2025 Chris Marchesi

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
    var sfc = try z2d.Surface.init(.image_surface_rgb, alloc, width, height);

    var context = z2d.Context.init(alloc, &sfc);
    defer context.deinit();
    context.setSourceToPixel(.{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } });
    context.setAntiAliasingMode(aa_mode);
    context.setLineWidth(10);

    for (0..7) |i| try line(&context, @floatFromInt(i), false, false);
    for (0..7) |i| try line(&context, @floatFromInt(i), true, false);
    for (0..7) |i| try line(&context, @floatFromInt(i), false, true);
    for (0..7) |i| try line(&context, @floatFromInt(i), true, true);

    return sfc;
}

fn line(context: *z2d.Context, i: f64, reverse: bool, round: bool) !void {
    defer context.resetPath();

    const saved_ctm = context.getTransformation();
    defer context.setTransformation(saved_ctm);

    const saved_line_width = context.getLineWidth();
    defer context.setLineWidth(saved_line_width);

    const saved_source = context.getSource();
    defer context.setSourceToPixel(saved_source.opaque_pattern.pixel);

    context.setLineCapMode(if (round) .round else .square);
    defer context.setLineCapMode(.butt);

    const y_offset = yoff: {
        var y: f64 = 50;
        if (reverse) y += 100;
        if (round) y += 200;
        break :yoff y;
    };

    if (reverse) {
        context.translate(i * 100 + 25, y_offset + 25 * @sin(math.pi / 6.0 * i));
        context.rotate(-math.pi / 6.0 * i);
        context.scale(2, 1);
    } else {
        context.translate(i * 100 + 25, y_offset - 25 * @sin(math.pi / 6.0 * i));
        context.rotate(math.pi / 6.0 * i);
        context.scale(2, 1);
    }
    if (reverse) {
        try context.moveTo(0, 0);
        try context.lineTo(25, 0);
    } else {
        try context.moveTo(25, 0);
        try context.lineTo(0, 0);
    }
    context.setLineWidth(lw: {
        var ux = saved_line_width;
        var uy = saved_line_width;
        try context.deviceToUserDistance(&ux, &uy);
        if (ux < uy) {
            break :lw uy;
        }
        break :lw ux;
    });
    try context.stroke();

    // Draw a hairline in red to help validate/measure
    context.setSourceToPixel(.{ .rgb = .{ .r = 0xF3, .g = 0x00, .b = 0x00 } });
    context.setLineWidth(1);

    try context.stroke();
}
