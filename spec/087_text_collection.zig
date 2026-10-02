// SPDX-License-Identifier: 0BSD
//   Copyright © 2024-2026 Chris Marchesi

//! Case: Draws text out of a font collection.
const Io = @import("std").Io;
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "087_text_collection";

pub fn render(io: Io, alloc: mem.Allocator, aa_mode: z2d.options.AntiAliasMode) !z2d.Surface {
    const width = 610;
    const height = 125;
    const text = "The quick brown fox jumps over the lazy dog";
    var sfc = try z2d.Surface.init(.image_surface_rgb, alloc, width, height);

    var context = z2d.Context.init(io, alloc, &sfc);
    defer context.deinit();
    context.setAntiAliasingMode(aa_mode);
    context.setSourceToPixel(.{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } });
    try context.setFontToBuffer(@embedFile("test-fonts/Inter-Regular-Italic-Bold.subset.ttc")); // Regular: index 0
    context.setFontSize(27);
    try context.showText(text, 10, 10);
    try context.setFontIndex(1); // Italic: index 1
    try context.showText(text, 10, 45);
    try context.setFontIndex(2); // Bold: index 2
    try context.showText(text, 10, 80);

    return sfc;
}
