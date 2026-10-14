// SPDX-License-Identifier: 0BSD
//   Copyright © 2024-2026 Chris Marchesi

//! Case: Renders a couple of glyphs in DejaVu Sans that seem to have incorrect
//! points (successive end points or off-curve points without any starting
//! on-curve point on a contour).
//!
//! Also provides a reasonable demo of how to use text shaping.
const Io = @import("std").Io;
const math = @import("std").math;
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "085_deja_sans_ignore_invalid_points";

pub fn render(io: Io, alloc: mem.Allocator, aa_mode: z2d.options.AntiAliasMode) !z2d.Surface {
    _ = io;

    const font_file = try z2d.font.File.loadBuffer(@embedFile("test-fonts/DejaVuSans.ttf"));
    var font = try font_file.loadFontIndex(0);
    const margin = 10;
    const font_size = 32;
    // Shape our text, positioned with a top-left origin based off our margin,
    // so we can render the path after we've created the appropriately sized
    // surface.
    var shaped = try z2d.text.shape(
        alloc,
        &font,
        "żu",
        margin,
        margin,
        .{ .size = font_size },
    );
    defer shaped.deinit(alloc);

    // Get our extents
    const font_extents = font.extents(font_size);
    const text_extents = shaped.extents();

    // Calculate our width based on our margin and the drawn text lsb.
    const sfc_width: i32 = sfc_width: {
        const width_raw = (margin + text_extents.x_bearing) * 2 + text_extents.width;
        break :sfc_width @intFromFloat(@ceil(width_raw));
    };

    // Use line spacing to calculate our surface height since that gets us some
    // natural margin. DejaVu Sans apparently has a line gap, but we don't need
    // it here, so we just use the ascender and descender directly.
    //
    // We also only want to only add to our bottom margin as much as we need
    // to, so we subtract the descender as we don't have any text that hangs
    // below it.
    const sfc_height: i32 =
        @intFromFloat(@ceil(@abs(font_extents.ascender) +
            @abs(font_extents.descender)) +
            margin + (margin - font_extents.descender));

    var sfc: z2d.Surface = try .init(.image_surface_rgb, alloc, sfc_width, sfc_height);
    const pattern: z2d.Pattern = .{ .opaque_pattern = .{ .pixel = .fromColor(.{ .rgb = .{ 1, 1, 1 } }) } };
    try z2d.painter.fill(alloc, &sfc, &pattern, shaped.path().nodes.items, .{ .anti_aliasing_mode = aa_mode });

    return sfc;
}
