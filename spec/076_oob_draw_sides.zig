// SPDX-License-Identifier: 0BSD
//   Copyright © 2024-2025 Chris Marchesi

//! Case: Interrogates out-of-bounds drawing under various cases, drawing
//! overlapping images on each four sides. The image should be clipped on the
//! corners, particularly on strokes, which should not not display where they
//! would be out-of-bounds (e.g., not snapped).
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "076_oob_draw_sides";

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

    // Top
    context.translate(0, -margin);
    try context.moveTo(cx - margin, cy);
    try context.lineTo(cx - margin, 0 - cy);
    try context.lineTo(cx + margin, 0 - cy);
    try context.lineTo(cx + margin, cy);
    try context.closePath();
    context.setSourceToPixel(.{ .rgb = .{ .r = 0x00, .g = 0xFF, .b = 0x00 } });
    try context.fill();
    context.setSourceToPixel(.{ .rgb = .{ .r = 0xFF, .g = 0x00, .b = 0xFF } });
    try context.stroke();

    // Bottom
    context.resetPath();
    context.setIdentity();
    context.translate(0, margin);
    try context.moveTo(cx - margin, cy);
    try context.lineTo(cx - margin, height + cy);
    try context.lineTo(cx + margin, height + cy);
    try context.lineTo(cx + margin, cy);
    try context.closePath();
    context.setSourceToPixel(.{ .rgb = .{ .r = 0x00, .g = 0xFF, .b = 0x00 } });
    try context.fill();
    context.setSourceToPixel(.{ .rgb = .{ .r = 0xFF, .g = 0x00, .b = 0xFF } });
    try context.stroke();

    // Left
    context.resetPath();
    context.setIdentity();
    context.translate(-margin, 0);
    try context.moveTo(cx, cy - margin);
    try context.lineTo(0 - cx, cy - margin);
    try context.lineTo(0 - cx, cy + margin);
    try context.lineTo(cx, cy + margin);
    try context.closePath();
    context.setSourceToPixel(.{ .rgb = .{ .r = 0x00, .g = 0xFF, .b = 0x00 } });
    try context.fill();
    context.setSourceToPixel(.{ .rgb = .{ .r = 0xFF, .g = 0x00, .b = 0xFF } });
    try context.stroke();

    // Right
    context.resetPath();
    context.setIdentity();
    context.translate(margin, 0);
    try context.moveTo(cx, cy - margin);
    try context.lineTo(width + cx, cy - margin);
    try context.lineTo(width + cx, cy + margin);
    try context.lineTo(cx, cy + margin);
    try context.closePath();
    context.setSourceToPixel(.{ .rgb = .{ .r = 0x00, .g = 0xFF, .b = 0x00 } });
    try context.fill();
    context.setSourceToPixel(.{ .rgb = .{ .r = 0xFF, .g = 0x00, .b = 0xFF } });
    try context.stroke();

    return sfc;
}
