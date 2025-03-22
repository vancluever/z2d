// SPDX-License-Identifier: 0BSD
//   Copyright © 2024-2025 Chris Marchesi

//! Case: Renders joined lines stretched and rotated using transformations.
//!
//! NOTE 1: My offsets to account for the rotations are a mess, I know :P
//! NOTE 2: Several of the line width calculations make degenerate lines, these
//! are intentional, as they behave the same in Cairo, so they serve as a way
//! to test correctness against Cairo.
const math = @import("std").math;
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "045_round_join_transforms";

pub fn render(alloc: mem.Allocator, aa_mode: z2d.options.AntiAliasMode) !z2d.Surface {
    const width = 800;
    const height = 600;
    var sfc = try z2d.Surface.init(.image_surface_rgb, alloc, width, height);

    var context = z2d.Context.init(alloc, &sfc);
    defer context.deinit();
    context.setSourceToPixel(.{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } });
    context.setAntiAliasingMode(aa_mode);
    context.setLineWidth(20);
    context.setLineCapMode(.round);
    context.setLineJoinMode(.round);

    for (0..12) |i| try line(&context, @floatFromInt(i));

    return sfc;
}

fn line(context: *z2d.Context, i: f64) !void {
    defer context.resetPath();

    const saved_ctm = context.getTransformation();
    defer context.setTransformation(saved_ctm);

    const saved_line_width = context.getLineWidth();
    defer context.setLineWidth(saved_line_width);

    const saved_source = context.getSource();
    defer context.setSourceToPixel(saved_source.opaque_pattern.pixel);

    const x_offset: f64 = 200 * @mod(i, 4.0) + 100 - 50 * @cos(math.pi / 6.0 * i);
    const y_offset: f64 = 200 * @floor(i / 4.0) + 75 - 37.5 * @sin(math.pi / 6.0 * i);

    context.translate(x_offset, y_offset);
    context.rotate(math.pi / 6.0 * i);
    context.scale(2, 1);
    try context.moveTo(0, 0);
    try context.lineTo(25, 75);
    try context.lineTo(50, 0);
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
