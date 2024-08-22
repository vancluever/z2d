// SPDX-License-Identifier: 0BSD
//   Copyright © 2024 Chris Marchesi

//! Case: Draws overlapping strokes in different directions to test that joins
//! with extremely acute angles overlap properly.
const debug = @import("std").debug;
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "037_stroke_join_overlap";

pub fn render(alloc: mem.Allocator, aa_mode: z2d.options.AntiAliasMode) !z2d.Surface {
    const width = 200;
    const height = 200;
    const sfc = try z2d.Surface.init(.image_surface_rgb, alloc, width, height);

    var context: z2d.Context = .{
        .surface = sfc,
        .pattern = .{
            .opaque_pattern = .{
                .pixel = .{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } }, // White on black
            },
        },
        .line_width = 5,
        .miter_limit = 4,
        .anti_aliasing_mode = aa_mode,
    };

    var path = z2d.Path.init(alloc);
    defer path.deinit();

    try path.moveTo(10, 10);
    try path.lineTo(50, 90);
    try path.lineTo(35, 50);

    try path.moveTo(190, 10);
    try path.lineTo(150, 90);
    try path.lineTo(165, 50);

    try path.moveTo(10, 190);
    try path.lineTo(50, 110);
    try path.lineTo(35, 150);

    try path.moveTo(190, 190);
    try path.lineTo(150, 110);
    try path.lineTo(165, 150);

    try context.stroke(alloc, path);

    return sfc;
}
