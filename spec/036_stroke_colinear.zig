// SPDX-License-Identifier: 0BSD
//   Copyright © 2024 Chris Marchesi

//! Case: Asserts correctness in colinear stroke operations.
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "036_stroke_colinear";

pub fn render(alloc: mem.Allocator, aa_mode: z2d.options.AntiAliasMode) !z2d.Surface {
    const width = 100;
    const height = 240;
    const sfc = try z2d.Surface.init(.image_surface_rgb, alloc, width, height);

    var context: z2d.Context = .{
        .surface = sfc,
        .pattern = .{
            .opaque_pattern = .{
                .pixel = .{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } }, // White on black
            },
        },
        .line_width = 4,
        .anti_aliasing_mode = aa_mode,
    };

    var path = try z2d.Path.initCapacity(alloc, 0);
    defer path.deinit(alloc);

    // clockwise
    try path.moveTo(alloc, 40, 50);
    try path.lineTo(alloc, 35, 60);
    try path.lineTo(alloc, 30, 70);
    try path.lineTo(alloc, 10, 50);

    // counter-clockwise
    try path.moveTo(alloc, 10, 10);
    try path.lineTo(alloc, 20, 20);
    try path.lineTo(alloc, 30, 30);
    try path.lineTo(alloc, 40, 10);

    // clockwise, closed
    try path.moveTo(alloc, 90, 50);
    try path.lineTo(alloc, 85, 60);
    try path.lineTo(alloc, 80, 70);
    try path.lineTo(alloc, 60, 50);
    try path.close(alloc);

    // counter-clockwise, closed
    try path.moveTo(alloc, 60, 10);
    try path.lineTo(alloc, 70, 20);
    try path.lineTo(alloc, 80, 30);
    try path.lineTo(alloc, 90, 10);
    try path.close(alloc);

    // single line, UL -> DR
    try path.moveTo(alloc, 10, 90);
    try path.lineTo(alloc, 25, 100);
    try path.lineTo(alloc, 40, 110);

    // single line, DL -> UR
    try path.moveTo(alloc, 10, 150);
    try path.lineTo(alloc, 25, 140);
    try path.lineTo(alloc, 40, 130);

    // single line, UR -> DL
    try path.moveTo(alloc, 90, 90);
    try path.lineTo(alloc, 75, 100);
    try path.lineTo(alloc, 60, 110);

    // single line, DR -> UL
    try path.moveTo(alloc, 90, 150);
    try path.lineTo(alloc, 75, 140);
    try path.lineTo(alloc, 60, 130);

    // switchback
    try path.moveTo(alloc, 10, 170);
    try path.lineTo(alloc, 30, 190);
    try path.lineTo(alloc, 20, 180);
    try path.lineTo(alloc, 40, 170);

    // switchback, reflected on x-axis
    try path.moveTo(alloc, 90, 170);
    try path.lineTo(alloc, 70, 190);
    try path.lineTo(alloc, 80, 180);
    try path.lineTo(alloc, 60, 170);

    // clockwise after start
    try path.moveTo(alloc, 40, 210);
    try path.lineTo(alloc, 30, 230);
    try path.lineTo(alloc, 20, 220);
    try path.lineTo(alloc, 10, 210);

    // counter-clockwise after start
    try path.moveTo(alloc, 60, 210);
    try path.lineTo(alloc, 70, 230);
    try path.lineTo(alloc, 80, 220);
    try path.lineTo(alloc, 90, 210);

    try context.stroke(alloc, path);

    return sfc;
}
