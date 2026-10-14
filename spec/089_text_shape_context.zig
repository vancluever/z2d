// SPDX-License-Identifier: 0BSD
//   Copyright © 2024-2026 Chris Marchesi

//! Case: Uses text shaping to get the exact extents of drawn text, and
//! positions that text in the center of a surface for drawing.
//!
//! This version uses API out of `Context`.
const Io = @import("std").Io;
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "089_text_shape_context";

pub fn render(io: Io, alloc: mem.Allocator, aa_mode: z2d.options.AntiAliasMode) !z2d.Surface {
    const text = "The quick brown fox jumps over the lazy dog";
    const font_buf = @embedFile("test-fonts/Inter-Regular.ttf");
    const font_size = 36.0;
    const width = 800;
    const height = 100;

    var sfc = try z2d.Surface.init(.image_surface_rgb, alloc, width, height);
    var context = z2d.Context.init(io, alloc, &sfc);
    defer context.deinit();
    context.setAntiAliasingMode(aa_mode);
    context.setSourceToPixel(.{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } });

    // Shape our text using our font at the size we used earlier to set up the
    // surface. We use the baseline for shaping to ease translation after the
    // fact.
    try context.setFontToBuffer(font_buf);
    context.setFontSize(font_size);
    context.setGlyphOrientation(.baseline);
    var shaped = try context.shapeText(text, 0, 0, null, .all);
    defer shaped.deinit(alloc);
    const text_extents = shaped.extents();

    // Set translation based on our shaping information, append the path, and fill.
    const tx: f64 = tx: {
        var t: f64 = -text_extents.x_bearing; // Shifts text bbox back to x=0 on left
        t += (@as(f64, @floatFromInt(width)) - text_extents.width) / 2.0; // Center horizontally
        break :tx t;
    };
    const ty: f64 = ty: {
        var t: f64 = -text_extents.y_bearing; // Shifts text bbox down to y=0 on top
        t += (@as(f64, @floatFromInt(height)) - text_extents.height) / 2.0; // Center vertically
        break :ty t;
    };
    context.translate(tx, ty);
    try context.appendPath(shaped.path());
    try context.fill();

    return sfc;
}
