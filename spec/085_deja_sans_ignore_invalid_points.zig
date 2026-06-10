// SPDX-License-Identifier: 0BSD
//   Copyright © 2024-2026 Chris Marchesi

//! Case: Renders a couple of glyphs in DejaVu Sans that seem to have incorrect
//! points (successive end points or off-curve points without any starting
//! on-curve point on a contour).
const Io = @import("std").Io;
const math = @import("std").math;
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "085_deja_sans_ignore_invalid_points";

pub fn render(io: Io, alloc: mem.Allocator, aa_mode: z2d.options.AntiAliasMode) !z2d.Surface {
    _ = io;

    var sfc: z2d.Surface = try .init(.image_surface_rgb, alloc, 58, 62);
    var font = try z2d.Font.loadBuffer(@embedFile("test-fonts/DejaVuSans.ttf"));
    const pattern: z2d.Pattern = .{ .opaque_pattern = .{ .pixel = .fromColor(.{ .rgb = .{ 1, 1, 1 } }) } };
    try z2d.text.show(
        alloc,
        &sfc,
        &pattern,
        &font,
        "żu",
        10,
        10,
        .{ .size = 32, .fill_opts = .{ .anti_aliasing_mode = aa_mode } },
    );

    return sfc;
}
