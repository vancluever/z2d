// SPDX-License-Identifier: 0BSD
//   Copyright © 2024-2026 Chris Marchesi

//! Case: Renders a closed dashed path that traverses multiple corners on the
//! close. This tests that direction is retained on the close and the correct
//! caps are applied on the correct contours.
const Io = @import("std").Io;
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "086_stroke_dash_close_multiple_join";

pub fn render(io: Io, alloc: mem.Allocator, aa_mode: z2d.options.AntiAliasMode) !z2d.Surface {
    const width = 300;
    const height = 300;
    var sfc = try z2d.Surface.init(.image_surface_rgb, alloc, width, height);

    var context = z2d.Context.init(io, alloc, &sfc);
    defer context.deinit();
    context.setSourceToPixel(.{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } });
    context.setAntiAliasingMode(aa_mode);
    context.setDashes(&.{ 90, 30 });
    context.setDashOffset(60);
    context.setLineWidth(6);

    try context.moveTo(50, 150);
    try context.lineTo(150, 250);
    try context.lineTo(250, 50);
    try context.lineTo(50, 100);
    try context.closePath();

    try context.stroke();

    return sfc;
}
