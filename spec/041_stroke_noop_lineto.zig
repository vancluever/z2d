// SPDX-License-Identifier: 0BSD
//   Copyright © 2024 Chris Marchesi

//! Case: Ensure no-op (degenerate) lineto operations are accounted for
//! properly and do not break strokes.
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "041_stroke_noop_lineto";

pub fn render(alloc: mem.Allocator, aa_mode: z2d.options.AntiAliasMode) !z2d.Surface {
    const width = 18;
    const height = 36;
    const sfc = try z2d.Surface.init(.image_surface_rgb, alloc, width, height);

    var context: z2d.Context = .{
        .surface = sfc,
        .pattern = .{
            .opaque_pattern = .{
                .pixel = .{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } }, // White on black
            },
        },
        .anti_aliasing_mode = aa_mode,
    };

    var path = try z2d.Path.initCapacity(alloc, 0);
    defer path.deinit(alloc);

    try path.moveTo(alloc, 9, 0);
    try path.lineTo(alloc, 9, 9);
    try path.lineTo(alloc, 0, 18);
    try path.lineTo(alloc, 0, 18);

    try context.stroke(alloc, path);

    return sfc;
}
