// SPDX-License-Identifier: 0BSD
//   Copyright © 2024-2025 Chris Marchesi

//! Case: Interrogates out-of-bounds drawing under various cases, drawing
//! overlapping images in the four corner quadrants. The image should be
//! clipped on the corners, particularly on strokes, which should not not
//! display where they would be out-of-bounds (e.g., not snapped).
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "075_oob_draw_corners";

pub fn render(alloc: mem.Allocator, aa_mode: z2d.options.AntiAliasMode) !z2d.Surface {
    const width = 300;
    const height = 300;
    const cx = width / 2;
    const cy = height / 2;
    const margin = 10;
    var sfc = try z2d.Surface.initPixel(
        z2d.pixel.Pixel.fromColor(.{ .rgb = .{ 0.33, 0.33, 0.33 } }),
        alloc,
        width,
        height,
    );

    var context = z2d.Context.init(alloc, &sfc);
    defer context.deinit();
    context.setAntiAliasingMode(aa_mode);

    // Overlap, top left
    context.translate(-margin, -margin);
    try context.lineTo(cx, cy);
    try context.lineTo(0 - cx, cy);
    try context.lineTo(cx, 0 - cy);
    try context.closePath();
    context.setSourceToPixel(.{ .rgb = .{ .r = 0x00, .g = 0xFF, .b = 0x00 } });
    try context.fill();
    context.setSourceToPixel(.{ .rgb = .{ .r = 0xFF, .g = 0x00, .b = 0xFF } });
    try context.stroke();

    // Overlap, top right
    context.resetPath();
    context.setIdentity();
    context.translate(margin, -margin);
    try context.moveTo(cx, cy);
    try context.lineTo(width + cx, cy);
    try context.lineTo(width + cx, 0 - cy);
    try context.lineTo(cx, 0 - cy);
    try context.closePath();
    context.setSourceToPixel(.{ .rgb = .{ .r = 0x00, .g = 0xFF, .b = 0x00 } });
    try context.fill();
    context.setSourceToPixel(.{ .rgb = .{ .r = 0xFF, .g = 0x00, .b = 0xFF } });
    try context.stroke();

    // Overlap, bottom left
    context.resetPath();
    context.setIdentity();
    context.translate(-margin, margin);
    try context.moveTo(cx, cy);
    try context.lineTo(0 - cx, cy);
    try context.lineTo(0 - cx, height + cy);
    try context.lineTo(cx, height + cy);
    try context.closePath();
    context.setSourceToPixel(.{ .rgb = .{ .r = 0x00, .g = 0xFF, .b = 0x00 } });
    try context.fill();
    context.setSourceToPixel(.{ .rgb = .{ .r = 0xFF, .g = 0x00, .b = 0xFF } });
    try context.stroke();

    // Overlap, bottom right
    context.resetPath();
    context.setIdentity();
    context.translate(margin, margin);
    try context.moveTo(cx, cy);
    try context.lineTo(width + cx, cy);
    try context.lineTo(width + cx, height + cy);
    try context.lineTo(cx, height + cy);
    try context.closePath();
    context.setSourceToPixel(.{ .rgb = .{ .r = 0x00, .g = 0xFF, .b = 0x00 } });
    try context.fill();
    context.setSourceToPixel(.{ .rgb = .{ .r = 0xFF, .g = 0x00, .b = 0xFF } });
    try context.stroke();

    return sfc;
}
