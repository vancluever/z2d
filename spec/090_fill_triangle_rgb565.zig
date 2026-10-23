// SPDX-License-Identifier: 0BSD
//   Copyright © 2024-2026 Chris Marchesi

//! Case: RGB565 color test using a triangle.
//!
//! Note that the PNG is exported as truecolor, just like normal RGB/RGBA
//! surfaces, due to PNG lacking a high-color format.
const std = @import("std");

const z2d = @import("z2d");

pub const filename = "090_fill_triangle_rgb565";

pub fn render(io: std.Io, alloc: std.mem.Allocator, aa_mode: z2d.options.AntiAliasMode) !z2d.Surface {
    const width = 300;
    const height = 300;
    var sfc = try z2d.Surface.init(.image_surface_rgb565, alloc, width, height);

    var context = z2d.Context.init(io, alloc, &sfc);
    defer context.deinit();
    const margin = 10;
    var stop_buffer: [2]z2d.gradient.Stop = undefined;
    var gradient = z2d.Gradient.init(.{
        .type = .{ .linear = .{
            .x0 = (width - margin * 2) / 2,
            .y0 = margin,
            .x1 = (width - margin * 2) / 2,
            .y1 = height - margin - 1,
        } },
        .stops = &stop_buffer,
        .method = .{ .hsl = .longer },
    });
    gradient.addStopAssumeCapacity(0, .{ .hsl = .{ 0, 1, 0.5 } });
    gradient.addStopAssumeCapacity(1, .{ .hsl = .{ 0, 1, 0.5 } });
    context.setSource(gradient.asPattern());
    context.setAntiAliasingMode(aa_mode);
    try context.moveTo(0 + margin, 0 + margin);
    try context.lineTo(width - margin - 1, 0 + margin);
    try context.lineTo(width / 2 - 1, height - margin - 1);
    try context.closePath();

    try context.fill();

    return sfc;
}
