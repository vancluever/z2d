//! Case: Renders multiple cornered lines with bevels and miters, the latter
//! with varying miter limits.
const debug = @import("std").debug;
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "019_stroke_bevel_miterlimit";

pub fn render(alloc: mem.Allocator, aa_mode: z2d.AntiAliasMode) !z2d.Surface {
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
    try path.moveTo(.{
        .x = 10,
        .y = 90,
    });
    try path.lineTo(.{
        .x = 80,
        .y = 60,
    });
    try path.lineTo(.{
        .x = 150,
        .y = 90,
    });

    // Line 2, ~99 degrees (dx = 35)
    try path.moveTo(.{
        .x = 170,
        .y = 90,
    });
    try path.lineTo(.{
        .x = 205,
        .y = 60,
    });
    try path.lineTo(.{
        .x = 240,
        .y = 90,
    });

    // Line 3, ~67 degrees (dx = 20)
    try path.moveTo(.{
        .x = 260,
        .y = 90,
    });
    try path.lineTo(.{
        .x = 280,
        .y = 60,
    });
    try path.lineTo(.{
        .x = 300,
        .y = 90,
    });

    // Line 4, ~28 degrees (dx = 7.5)
    try path.moveTo(.{
        .x = 320,
        .y = 90,
    });
    try path.lineTo(.{
        .x = 327.5,
        .y = 60,
    });
    try path.lineTo(.{
        .x = 335,
        .y = 90,
    });

    // Line 5, ~18 degrees (dx = 5)
    try path.moveTo(.{
        .x = 355,
        .y = 90,
    });
    try path.lineTo(.{
        .x = 360,
        .y = 60,
    });
    try path.lineTo(.{
        .x = 365,
        .y = 90,
    });

    try context.stroke(alloc, path);

    // First miter case, rendered with a miter limit of 4. Note that this is
    // the SVG default (see the MDN page quoted higher up).
    context.line_join_mode = .miter;
    context.miter_limit = 4;
    path.reset();

    // Line 1, ~130 degrees (dx = 70)
    try path.moveTo(.{
        .x = 10,
        .y = 190,
    });
    try path.lineTo(.{
        .x = 80,
        .y = 160,
    });
    try path.lineTo(.{
        .x = 150,
        .y = 190,
    });

    // Line 2, ~99 degrees (dx = 35)
    try path.moveTo(.{
        .x = 170,
        .y = 190,
    });
    try path.lineTo(.{
        .x = 205,
        .y = 160,
    });
    try path.lineTo(.{
        .x = 240,
        .y = 190,
    });

    // Line 3, ~67 degrees (dx = 20)
    try path.moveTo(.{
        .x = 260,
        .y = 190,
    });
    try path.lineTo(.{
        .x = 280,
        .y = 160,
    });
    try path.lineTo(.{
        .x = 300,
        .y = 190,
    });

    // Line 4, ~28 degrees (dx = 7.5)
    try path.moveTo(.{
        .x = 320,
        .y = 190,
    });
    try path.lineTo(.{
        .x = 327.5,
        .y = 160,
    });
    try path.lineTo(.{
        .x = 335,
        .y = 190,
    });

    // Line 5, ~18 degrees (dx = 5)
    try path.moveTo(.{
        .x = 355,
        .y = 190,
    });
    try path.lineTo(.{
        .x = 360,
        .y = 160,
    });
    try path.lineTo(.{
        .x = 365,
        .y = 190,
    });

    try context.stroke(alloc, path);

    // Second miter case, rendered with a miter limit of 1
    context.miter_limit = 1;
    path.reset();

    // Line 1, ~130 degrees (dx = 70)
    try path.moveTo(.{
        .x = 10,
        .y = 290,
    });
    try path.lineTo(.{
        .x = 80,
        .y = 260,
    });
    try path.lineTo(.{
        .x = 150,
        .y = 290,
    });

    // Line 2, ~99 degrees (dx = 35)
    try path.moveTo(.{
        .x = 170,
        .y = 290,
    });
    try path.lineTo(.{
        .x = 205,
        .y = 260,
    });
    try path.lineTo(.{
        .x = 240,
        .y = 290,
    });

    // Line 3, ~67 degrees (dx = 20)
    try path.moveTo(.{
        .x = 260,
        .y = 290,
    });
    try path.lineTo(.{
        .x = 280,
        .y = 260,
    });
    try path.lineTo(.{
        .x = 300,
        .y = 290,
    });

    // Line 4, ~28 degrees (dx = 7.5)
    try path.moveTo(.{
        .x = 320,
        .y = 290,
    });
    try path.lineTo(.{
        .x = 327.5,
        .y = 260,
    });
    try path.lineTo(.{
        .x = 335,
        .y = 290,
    });

    // Line 5, ~18 degrees (dx = 5)
    try path.moveTo(.{
        .x = 355,
        .y = 290,
    });
    try path.lineTo(.{
        .x = 360,
        .y = 260,
    });
    try path.lineTo(.{
        .x = 365,
        .y = 290,
    });

    try context.stroke(alloc, path);

    // Third miter case, rendered with a miter limit of 6
    context.miter_limit = 6;
    path.reset();

    // Line 1, ~130 degrees (dx = 70)
    try path.moveTo(.{
        .x = 10,
        .y = 390,
    });
    try path.lineTo(.{
        .x = 80,
        .y = 360,
    });
    try path.lineTo(.{
        .x = 150,
        .y = 390,
    });

    // Line 2, ~99 degrees (dx = 35)
    try path.moveTo(.{
        .x = 170,
        .y = 390,
    });
    try path.lineTo(.{
        .x = 205,
        .y = 360,
    });
    try path.lineTo(.{
        .x = 240,
        .y = 390,
    });

    // Line 3, ~67 degrees (dx = 20)
    try path.moveTo(.{
        .x = 260,
        .y = 390,
    });
    try path.lineTo(.{
        .x = 280,
        .y = 360,
    });
    try path.lineTo(.{
        .x = 300,
        .y = 390,
    });

    // Line 4, ~28 degrees (dx = 7.5)
    try path.moveTo(.{
        .x = 320,
        .y = 390,
    });
    try path.lineTo(.{
        .x = 327.5,
        .y = 360,
    });
    try path.lineTo(.{
        .x = 335,
        .y = 390,
    });

    // Line 5, ~18 degrees (dx = 5)
    try path.moveTo(.{
        .x = 355,
        .y = 390,
    });
    try path.lineTo(.{
        .x = 360,
        .y = 360,
    });
    try path.lineTo(.{
        .x = 365,
        .y = 390,
    });

    try context.stroke(alloc, path);

    // Fourth miter case, rendered with a miter limit of 10 (default)
    context.miter_limit = 10;
    path.reset();

    // Line 1, ~130 degrees (dx = 70)
    try path.moveTo(.{
        .x = 10,
        .y = 490,
    });
    try path.lineTo(.{
        .x = 80,
        .y = 460,
    });
    try path.lineTo(.{
        .x = 150,
        .y = 490,
    });

    // Line 2, ~99 degrees (dx = 35)
    try path.moveTo(.{
        .x = 170,
        .y = 490,
    });
    try path.lineTo(.{
        .x = 205,
        .y = 460,
    });
    try path.lineTo(.{
        .x = 240,
        .y = 490,
    });

    // Line 3, ~67 degrees (dx = 20)
    try path.moveTo(.{
        .x = 260,
        .y = 490,
    });
    try path.lineTo(.{
        .x = 280,
        .y = 460,
    });
    try path.lineTo(.{
        .x = 300,
        .y = 490,
    });

    // Line 4, ~28 degrees (dx = 7.5)
    try path.moveTo(.{
        .x = 320,
        .y = 490,
    });
    try path.lineTo(.{
        .x = 327.5,
        .y = 460,
    });
    try path.lineTo(.{
        .x = 335,
        .y = 490,
    });

    // Line 5, ~18 degrees (dx = 5)
    try path.moveTo(.{
        .x = 355,
        .y = 490,
    });
    try path.lineTo(.{
        .x = 360,
        .y = 460,
    });
    try path.lineTo(.{
        .x = 365,
        .y = 490,
    });

    try context.stroke(alloc, path);

    return sfc;
}
