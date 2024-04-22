// SPDX-License-Identifier: 0BSD
//   Copyright © 2024 Chris Marchesi

//! Case: Renders arcs as a demonstration of how this can be done with bezier
//! primitives.
const debug = @import("std").debug;
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "032_fill_arc";

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
        .anti_aliasing_mode = aa_mode,
    };

    var path = z2d.Path.init(alloc);
    defer path.deinit();

    // For approximating a circle w/bezier
    // https://stackoverflow.com/a/27863181
    const ratio = 0.552284749831;
    const center_y = 150;

    {
        const center_x = 100;
        const radius = 50;
        const p12 = radius * ratio;

        try path.moveTo(center_x, center_y - radius);
        try path.curveTo(center_x + p12, center_y - radius, center_x + radius, center_y - p12, center_x + radius, center_y);
        try path.curveTo(center_x + radius, center_y + p12, center_x + p12, center_y + radius, center_x, center_y + radius);
        try path.curveTo(center_x - p12, center_y + radius, center_x - radius, center_y + p12, center_x - radius, center_y);
        try path.curveTo(center_x - radius, center_y - p12, center_x - p12, center_y - radius, center_x, center_y - radius);
        try path.close();
        try context.fill(alloc, path);
    }

    {
        const center_x = 200;
        const radius_major = 50;
        const radius_minor = 25;
        const p12_major = radius_major * ratio;
        const p12_minor = radius_minor * ratio;

        path.reset();
        try path.moveTo(center_x, center_y - radius_major);
        try path.curveTo(center_x + p12_minor, center_y - radius_major, center_x + radius_minor, center_y - p12_major, center_x + radius_minor, center_y);
        try path.curveTo(center_x + radius_minor, center_y + p12_major, center_x + p12_minor, center_y + radius_major, center_x, center_y + radius_major);
        try path.curveTo(center_x - p12_minor, center_y + radius_major, center_x - radius_minor, center_y + p12_major, center_x - radius_minor, center_y);
        try path.curveTo(center_x - radius_minor, center_y - p12_major, center_x - p12_minor, center_y - radius_major, center_x, center_y - radius_major);
        try path.close();
        try context.fill(alloc, path);
    }

    return sfc;
}
