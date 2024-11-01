// SPDX-License-Identifier: 0BSD
//   Copyright © 2024 Chris Marchesi

//! Case: Renders unclosed lines with rounded joins.
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "018_stroke_square_spiral_round";

pub fn render(alloc: mem.Allocator, aa_mode: z2d.options.AntiAliasMode) !z2d.Surface {
    const width = 240;
    const height = 260;
    const sfc = try z2d.Surface.init(.image_surface_rgb, alloc, width, height);

    var context: z2d.Context = .{
        .surface = sfc,
        .pattern = .{
            .opaque_pattern = .{
                .pixel = .{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } }, // White on black
            },
        },
        .line_width = 10,
        .line_join_mode = .round,
        .anti_aliasing_mode = aa_mode,
    };

    var path = try z2d.Path.initCapacity(alloc, 0);
    defer path.deinit(alloc);

    try path.moveTo(alloc, 10, 10);
    try path.lineTo(alloc, 100, 20);
    try path.lineTo(alloc, 110, 120);
    try path.lineTo(alloc, 10, 110);
    try path.lineTo(alloc, 20, 30);
    try path.lineTo(alloc, 90, 40);
    try path.lineTo(alloc, 95, 100);
    try path.lineTo(alloc, 30, 95);
    try path.lineTo(alloc, 30, 50);
    try path.lineTo(alloc, 80, 50);
    try path.lineTo(alloc, 75, 85);
    try path.lineTo(alloc, 45, 80);
    try path.lineTo(alloc, 50, 60);
    try path.lineTo(alloc, 65, 70);

    ////////////////////
    const x_offset = 120;

    try path.moveTo(alloc, x_offset + 110, 10);
    try path.lineTo(alloc, x_offset + 20, 20);
    try path.lineTo(alloc, x_offset + 10, 120);
    try path.lineTo(alloc, x_offset + 110, 110);
    try path.lineTo(alloc, x_offset + 100, 30);
    try path.lineTo(alloc, x_offset + 30, 40);
    try path.lineTo(alloc, x_offset + 25, 100);
    try path.lineTo(alloc, x_offset + 90, 95);
    try path.lineTo(alloc, x_offset + 90, 50);
    try path.lineTo(alloc, x_offset + 40, 50);
    try path.lineTo(alloc, x_offset + 45, 85);
    try path.lineTo(alloc, x_offset + 75, 80);
    try path.lineTo(alloc, x_offset + 70, 60);
    try path.lineTo(alloc, x_offset + 55, 70);

    ////////////////////
    const y_offset = 130;

    try path.moveTo(alloc, 10, y_offset + 120);
    try path.lineTo(alloc, 100, y_offset + 110);
    try path.lineTo(alloc, 110, y_offset + 10);
    try path.lineTo(alloc, 10, y_offset + 20);
    try path.lineTo(alloc, 20, y_offset + 100);
    try path.lineTo(alloc, 90, y_offset + 90);
    try path.lineTo(alloc, 95, y_offset + 30);
    try path.lineTo(alloc, 30, y_offset + 35);
    try path.lineTo(alloc, 30, y_offset + 80);
    try path.lineTo(alloc, 80, y_offset + 80);
    try path.lineTo(alloc, 75, y_offset + 45);
    try path.lineTo(alloc, 45, y_offset + 50);
    try path.lineTo(alloc, 50, y_offset + 70);
    try path.lineTo(alloc, 65, y_offset + 60);

    ////////////////////

    try path.moveTo(alloc, x_offset + 110, y_offset + 120);
    try path.lineTo(alloc, x_offset + 20, y_offset + 110);
    try path.lineTo(alloc, x_offset + 10, y_offset + 10);
    try path.lineTo(alloc, x_offset + 110, y_offset + 20);
    try path.lineTo(alloc, x_offset + 100, y_offset + 100);
    try path.lineTo(alloc, x_offset + 30, y_offset + 90);
    try path.lineTo(alloc, x_offset + 25, y_offset + 30);
    try path.lineTo(alloc, x_offset + 90, y_offset + 35);
    try path.lineTo(alloc, x_offset + 90, y_offset + 80);
    try path.lineTo(alloc, x_offset + 40, y_offset + 80);
    try path.lineTo(alloc, x_offset + 45, y_offset + 45);
    try path.lineTo(alloc, x_offset + 75, y_offset + 50);
    try path.lineTo(alloc, x_offset + 70, y_offset + 70);
    try path.lineTo(alloc, x_offset + 55, y_offset + 60);

    try context.stroke(alloc, path);

    return sfc;
}
