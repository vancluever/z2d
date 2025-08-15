// SPDX-License-Identifier: 0BSD
//   Copyright © 2024-2025 Chris Marchesi

//! Case: Interrogates out-of-bounds drawing under various cases, drawing rects
//! completely out-of-bounds in various places. This is ultimately a no-op
//! test, the image should be completely black.
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "077_oob_draw_full_outside";

pub fn render(alloc: mem.Allocator, aa_mode: z2d.options.AntiAliasMode) !z2d.Surface {
    const width = 300;
    const height = 300;

    var sfc = try z2d.Surface.init(.image_surface_rgb, alloc, width, height);

    var context = z2d.Context.init(alloc, &sfc);
    defer context.deinit();
    context.setAntiAliasingMode(aa_mode);

    try draw(&context, -width, -height); // top left
    try draw(&context, width * 2, -height); // top right
    try draw(&context, width * 2, height * 2); // bottom left
    try draw(&context, -width, height * 2); // bottom right

    const cx = width / 2;
    const cy = width / 2;
    try draw(&context, -width, cy); // left
    try draw(&context, width * 2, cy); // right
    try draw(&context, cx, -height); // top
    try draw(&context, cx, height * 2); // bottom
    return sfc;
}

fn draw(context: *z2d.Context, cx: f64, cy: f64) !void {
    context.resetPath();
    context.setIdentity();
    context.translate(cx, cy);
    try context.moveTo(cx - 20, cy - 20);
    try context.lineTo(cx + 20, cy - 20);
    try context.lineTo(cx + 20, cy + 20);
    try context.lineTo(cx - 20, cy + 20);
    try context.closePath();
    context.setSourceToPixel(.{ .rgb = .{ .r = 0x00, .g = 0xFF, .b = 0x00 } });
    try context.fill();
    context.setSourceToPixel(.{ .rgb = .{ .r = 0xFF, .g = 0x00, .b = 0xFF } });
    try context.stroke();
}
