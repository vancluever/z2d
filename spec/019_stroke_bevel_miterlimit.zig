// SPDX-License-Identifier: 0BSD
//   Copyright © 2024 Chris Marchesi

//! Case: Renders multiple cornered lines with bevels and miters, the latter
//! with varying miter limits.
const debug = @import("std").debug;
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "019_stroke_bevel_miterlimit";

pub fn render(alloc: mem.Allocator, aa_mode: z2d.options.AntiAliasMode) !z2d.Surface {
    const width = 375;
    const height = 560;
    const sfc = try z2d.Surface.init(.image_surface_rgb, alloc, width, height);

    var context: z2d.Context = .{
        .surface = sfc,
        .pattern = .{
            .opaque_pattern = .{
                .pixel = .{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } }, // White on black
            },
        },
        .line_width = 5,
        .line_join_mode = .bevel,
        .anti_aliasing_mode = aa_mode,
    };

    // We render 5 different paths with increasingly smaller angles to help
    // detect the miter threshold. Our base case (the first), however, uses all
    // bevels.
    //
    // Example is inspired by
    // https://developer.mozilla.org/en-US/docs/Web/SVG/Attribute/stroke-miterlimit.
    // NOTE: This does not test the default miter limit as it's very high (11
    // degrees, and you can see how tight even 18 degrees is here). We probably
    // should test the default limit via unit testing.
    var path = z2d.Path.init(alloc);
    defer path.deinit();

    // Line 1, ~130 degrees (dx = 70)
    try path.moveTo(10, 90);
    try path.lineTo(80, 60);
    try path.lineTo(150, 90);

    // Line 2, ~99 degrees (dx = 35)
    try path.moveTo(170, 90);
    try path.lineTo(205, 60);
    try path.lineTo(240, 90);

    // Line 3, ~67 degrees (dx = 20)
    try path.moveTo(260, 90);
    try path.lineTo(280, 60);
    try path.lineTo(300, 90);

    // Line 4, ~28 degrees (dx = 7.5)
    try path.moveTo(320, 90);
    try path.lineTo(327.5, 60);
    try path.lineTo(335, 90);

    // Line 5, ~18 degrees (dx = 5)
    try path.moveTo(355, 90);
    try path.lineTo(360, 60);
    try path.lineTo(365, 90);

    try context.stroke(alloc, path);

    // First miter case, rendered with a miter limit of 4. Note that this is
    // the SVG default (see the MDN page quoted higher up).
    context.line_join_mode = .miter;
    context.miter_limit = 4;
    path.reset();

    // Line 1, ~130 degrees (dx = 70)
    try path.moveTo(10, 190);
    try path.lineTo(80, 160);
    try path.lineTo(150, 190);

    // Line 2, ~99 degrees (dx = 35)
    try path.moveTo(170, 190);
    try path.lineTo(205, 160);
    try path.lineTo(240, 190);

    // Line 3, ~67 degrees (dx = 20)
    try path.moveTo(260, 190);
    try path.lineTo(280, 160);
    try path.lineTo(300, 190);

    // Line 4, ~28 degrees (dx = 7.5)
    try path.moveTo(320, 190);
    try path.lineTo(327.5, 160);
    try path.lineTo(335, 190);

    // Line 5, ~18 degrees (dx = 5)
    try path.moveTo(355, 190);
    try path.lineTo(360, 160);
    try path.lineTo(365, 190);

    try context.stroke(alloc, path);

    // Second miter case, rendered with a miter limit of 1
    context.miter_limit = 1;
    path.reset();

    // Line 1, ~130 degrees (dx = 70)
    try path.moveTo(10, 290);
    try path.lineTo(80, 260);
    try path.lineTo(150, 290);

    // Line 2, ~99 degrees (dx = 35)
    try path.moveTo(170, 290);
    try path.lineTo(205, 260);
    try path.lineTo(240, 290);

    // Line 3, ~67 degrees (dx = 20)
    try path.moveTo(260, 290);
    try path.lineTo(280, 260);
    try path.lineTo(300, 290);

    // Line 4, ~28 degrees (dx = 7.5)
    try path.moveTo(320, 290);
    try path.lineTo(327.5, 260);
    try path.lineTo(335, 290);

    // Line 5, ~18 degrees (dx = 5)
    try path.moveTo(355, 290);
    try path.lineTo(360, 260);
    try path.lineTo(365, 290);

    try context.stroke(alloc, path);

    // Third miter case, rendered with a miter limit of 6
    context.miter_limit = 6;
    path.reset();

    // Line 1, ~130 degrees (dx = 70)
    try path.moveTo(10, 390);
    try path.lineTo(80, 360);
    try path.lineTo(150, 390);

    // Line 2, ~99 degrees (dx = 35)
    try path.moveTo(170, 390);
    try path.lineTo(205, 360);
    try path.lineTo(240, 390);

    // Line 3, ~67 degrees (dx = 20)
    try path.moveTo(260, 390);
    try path.lineTo(280, 360);
    try path.lineTo(300, 390);

    // Line 4, ~28 degrees (dx = 7.5)
    try path.moveTo(320, 390);
    try path.lineTo(327.5, 360);
    try path.lineTo(335, 390);

    // Line 5, ~18 degrees (dx = 5)
    try path.moveTo(355, 390);
    try path.lineTo(360, 360);
    try path.lineTo(365, 390);

    try context.stroke(alloc, path);

    // Fourth miter case, rendered with a miter limit of 10 (default)
    context.miter_limit = 10;
    path.reset();

    // Line 1, ~130 degrees (dx = 70)
    try path.moveTo(10, 490);
    try path.lineTo(80, 460);
    try path.lineTo(150, 490);

    // Line 2, ~99 degrees (dx = 35)
    try path.moveTo(170, 490);
    try path.lineTo(205, 460);
    try path.lineTo(240, 490);

    // Line 3, ~67 degrees (dx = 20)
    try path.moveTo(260, 490);
    try path.lineTo(280, 460);
    try path.lineTo(300, 490);

    // Line 4, ~28 degrees (dx = 7.5)
    try path.moveTo(320, 490);
    try path.lineTo(327.5, 460);
    try path.lineTo(335, 490);

    // Line 5, ~18 degrees (dx = 5)
    try path.moveTo(355, 490);
    try path.lineTo(360, 460);
    try path.lineTo(365, 490);

    try context.stroke(alloc, path);

    return sfc;
}
