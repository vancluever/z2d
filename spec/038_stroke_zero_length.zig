// SPDX-License-Identifier: 0BSD
//   Copyright © 2024 Chris Marchesi

//! Case: Renders and fills a triangle on a 300x300 surface.
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "038_stroke_zero_length";

pub fn render(alloc: mem.Allocator, aa_mode: z2d.options.AntiAliasMode) !z2d.Surface {
    const width = 60;
    const height = 60;
    const sfc = try z2d.Surface.init(.image_surface_rgb, alloc, width, height);

    var context: z2d.Context = .{
        .surface = sfc,
        .pattern = .{
            .opaque_pattern = .{
                .pixel = .{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } }, // White on black
            },
        },
        .line_width = 10,
        .line_cap_mode = .round,
        .anti_aliasing_mode = aa_mode,
    };

    var path = try z2d.Path.initCapacity(alloc, 0);
    defer path.deinit(alloc);

    try path.moveTo(alloc, 10, 10);
    try path.close(alloc);

    try path.moveTo(alloc, 30, 30);
    try path.lineTo(alloc, 30, 30);
    try path.lineTo(alloc, 30, 30);
    try path.close(alloc);

    // This should not draw anything
    try path.moveTo(alloc, 50, 50);

    try context.stroke(alloc, path);

    return sfc;
}
