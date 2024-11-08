// SPDX-License-Identifier: 0BSD
//   Copyright © 2024 Chris Marchesi

//! Case: Renders and fills a triangle on a 300x300 surface, using a
//! statically-allocated path buffer.
//!
//! This also demonstrates the use of the unmanaged functions in the painter,
//! completely avoiding the use fo a Context.
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "048_fill_triangle_static";

pub fn render(alloc: mem.Allocator, aa_mode: z2d.options.AntiAliasMode) !z2d.Surface {
    const width = 300;
    const height = 300;
    var sfc = try z2d.Surface.init(.image_surface_rgb, alloc, width, height);

    var path: z2d.StaticPath(5) = .{};
    path.init();

    const margin = 10;
    path.moveTo(0 + margin, 0 + margin);
    path.lineTo(width - margin - 1, 0 + margin);
    path.lineTo(width / 2 - 1, height - margin - 1);
    path.close();

    try z2d.painter.fill(
        alloc,
        &sfc,
        &.{
            .opaque_pattern = .{
                .pixel = .{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } }, // White on black
            },
        },
        &path.nodes,
        .{ .anti_aliasing_mode = aa_mode },
    );

    return sfc;
}
