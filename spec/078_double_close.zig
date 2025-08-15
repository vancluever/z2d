// SPDX-License-Identifier: 0BSD
//   Copyright © 2024-2025 Chris Marchesi

//! Case: Ensures double close works, under both fill and stroke.
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "078_double_close";

pub fn render(alloc: mem.Allocator, aa_mode: z2d.options.AntiAliasMode) !z2d.Surface {
    const width = 300;
    const height = 300;
    var sfc = try z2d.Surface.initPixel(
        z2d.pixel.Pixel.fromColor(.{ .rgb = .{ 0.33, 0.33, 0.33 } }),
        alloc,
        width,
        height,
    );

    var context = z2d.Context.init(alloc, &sfc);
    defer context.deinit();
    context.setAntiAliasingMode(aa_mode);

    try context.moveTo(49, 49);
    try context.lineTo(250, 49);
    try context.lineTo(250, 250);
    try context.lineTo(49, 250);
    try context.closePath();
    try context.closePath();
    context.setSourceToPixel(.{ .rgb = .{ .r = 0x00, .g = 0xFF, .b = 0x00 } });
    try context.fill();
    context.setSourceToPixel(.{ .rgb = .{ .r = 0xFF, .g = 0x00, .b = 0xFF } });
    try context.stroke();

    return sfc;
}
