// SPDX-License-Identifier: 0BSD
//   Copyright © 2024 Chris Marchesi

//! Case: Renders arcs as a demonstration of how this can be done with bezier
//! primitives.
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "032_fill_arc";

pub fn render(alloc: mem.Allocator, aa_mode: z2d.options.AntiAliasMode) !z2d.Surface {
    const width = 300;
    const height = 300;
    var sfc = try z2d.Surface.init(.image_surface_rgb, alloc, width, height);

    var context = try z2d.Context.init(alloc, &sfc);
    defer context.deinit();
    context.setSource(.{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } });
    context.setAntiAliasingMode(aa_mode);

    // For approximating a circle w/bezier
    // https://stackoverflow.com/a/27863181
    const ratio = 0.552284749831;
    const center_y = 150;

    {
        const center_x = 100;
        const radius = 50;
        const p12 = radius * ratio;

        try context.moveTo(center_x, center_y - radius);
        try context.curveTo(center_x + p12, center_y - radius, center_x + radius, center_y - p12, center_x + radius, center_y);
        try context.curveTo(center_x + radius, center_y + p12, center_x + p12, center_y + radius, center_x, center_y + radius);
        try context.curveTo(center_x - p12, center_y + radius, center_x - radius, center_y + p12, center_x - radius, center_y);
        try context.curveTo(center_x - radius, center_y - p12, center_x - p12, center_y - radius, center_x, center_y - radius);
        try context.close();
        try context.fill();
    }

    {
        const center_x = 200;
        const radius_major = 50;
        const radius_minor = 25;
        const p12_major = radius_major * ratio;
        const p12_minor = radius_minor * ratio;

        context.resetPath();
        try context.moveTo(center_x, center_y - radius_major);
        try context.curveTo(center_x + p12_minor, center_y - radius_major, center_x + radius_minor, center_y - p12_major, center_x + radius_minor, center_y);
        try context.curveTo(center_x + radius_minor, center_y + p12_major, center_x + p12_minor, center_y + radius_major, center_x, center_y + radius_major);
        try context.curveTo(center_x - p12_minor, center_y + radius_major, center_x - radius_minor, center_y + p12_major, center_x - radius_minor, center_y);
        try context.curveTo(center_x - radius_minor, center_y - p12_major, center_x - p12_minor, center_y - radius_major, center_x, center_y - radius_major);
        try context.close();
        try context.fill();
    }

    return sfc;
}
