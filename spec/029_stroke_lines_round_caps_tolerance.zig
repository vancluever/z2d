// SPDX-License-Identifier: 0BSD
//   Copyright © 2024 Chris Marchesi

//! Case: Renders multiple lines, round-capped at varying levels of tolerance.
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "029_stroke_lines_round_caps_tolerance";

pub fn render(alloc: mem.Allocator, aa_mode: z2d.options.AntiAliasMode) !z2d.Surface {
    const width = 300;
    const height = 300;
    const sfc = try z2d.Surface.init(.image_surface_rgb, alloc, width, height);

    var context: z2d.Context = .{
        .surface = sfc,
        .pattern = .{
            .opaque_pattern = .{
                .pixel = .{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } }, // White on black
            },
        },
        .line_cap_mode = .round,
        .line_join_mode = .round,
        .line_width = 30,
        .anti_aliasing_mode = aa_mode,
    };

    var path = try z2d.Path.initCapacity(alloc, 0);
    defer path.deinit(alloc);

    try path.moveTo(alloc, 30, 50);
    try path.lineTo(alloc, 270, 50);
    try context.stroke(alloc, path);

    context.tolerance = 3;
    path.reset();
    try path.moveTo(alloc, 30, 150);
    try path.lineTo(alloc, 270, 150);
    try context.stroke(alloc, path);

    context.tolerance = 10;
    path.reset();
    try path.moveTo(alloc, 30, 250);
    try path.lineTo(alloc, 270, 250);
    try context.stroke(alloc, path);

    return sfc;
}
