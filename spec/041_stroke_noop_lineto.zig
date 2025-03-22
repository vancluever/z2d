// SPDX-License-Identifier: 0BSD
//   Copyright © 2024 Chris Marchesi

//! Case: Ensure no-op (degenerate) lineto operations are accounted for
//! properly and do not break strokes.
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "041_stroke_noop_lineto";

pub fn render(alloc: mem.Allocator, aa_mode: z2d.options.AntiAliasMode) !z2d.Surface {
    const width = 18;
    const height = 36;
    var sfc = try z2d.Surface.init(.image_surface_rgb, alloc, width, height);

    var context = z2d.Context.init(alloc, &sfc);
    defer context.deinit();
    context.setSourceToPixel(.{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } });
    context.setAntiAliasingMode(aa_mode);

    try context.moveTo(9, 0);
    try context.lineTo(9, 9);
    try context.lineTo(0, 18);
    try context.lineTo(0, 18);

    try context.stroke();

    return sfc;
}
