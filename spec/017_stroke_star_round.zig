// SPDX-License-Identifier: 0BSD
//   Copyright © 2024 Chris Marchesi

//! Case: Renders and strokes a star on a 300x300 surface with rounded corners.
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "017_stroke_star_round";

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
        .line_width = 10,
        .line_join_mode = .round,
        .anti_aliasing_mode = aa_mode,
    };

    var path = try z2d.Path.initCapacity(alloc, 0);
    defer path.deinit(alloc);

    const margin = 20;
    const x_scale = 3;
    const y_scale = 5;
    // With all 5 points numbered 1-5 clockwise, we draw odds first (1, 3, 5),
    // then evens (4, 2), with the close connecting 4 and 1.
    try path.moveTo(alloc, width / 2, 0 + margin); // 1
    try path.lineTo(alloc, width - margin * x_scale - 1, height - margin - 1); // 3
    try path.lineTo(alloc, 0 + margin, 0 + margin * y_scale); // 5
    try path.lineTo(alloc, width - margin - 1, 0 + margin * y_scale); // 2
    try path.lineTo(alloc, 0 + margin * x_scale, height - margin - 1); // 4
    try path.close(alloc);

    try context.stroke(alloc, path);

    return sfc;
}
