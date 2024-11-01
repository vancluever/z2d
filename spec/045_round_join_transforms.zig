// SPDX-License-Identifier: 0BSD
//   Copyright © 2024 Chris Marchesi

//! Case: Renders joined lines stretched and rotated using transformations.
//!
//! NOTE 1: My offsets to account for the rotations are a mess, I know :P
//! NOTE 2: Several of the line width calculations make degenerate lines, these
//! are intentional, as they behave the same in Cairo, so they serve as a way
//! to test correctness against Cairo.
const math = @import("std").math;
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "045_round_join_transforms";

pub fn render(alloc: mem.Allocator, aa_mode: z2d.options.AntiAliasMode) !z2d.Surface {
    const width = 800;
    const height = 600;
    const sfc = try z2d.Surface.init(.image_surface_rgb, alloc, width, height);

    var context: z2d.Context = .{
        .surface = sfc,
        .pattern = .{
            .opaque_pattern = .{
                .pixel = .{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } }, // White on black
            },
        },
        .anti_aliasing_mode = aa_mode,
        .line_width = 20,
        .line_cap_mode = .round,
        .line_join_mode = .round,
    };

    for (0..12) |i| try line(alloc, &context, @floatFromInt(i));

    return sfc;
}

fn line(alloc: mem.Allocator, context: *z2d.Context, i: f64) !void {
    const saved_context_ctm = context.transformation;
    defer context.transformation = saved_context_ctm;

    const saved_line_width = context.line_width;
    defer context.line_width = saved_line_width;

    const saved_pattern = context.pattern;
    defer context.pattern = saved_pattern;

    const x_offset: f64 = 200 * @mod(i, 4.0) + 100 - 50 * @cos(math.pi / 6.0 * i);
    const y_offset: f64 = 200 * @floor(i / 4.0) + 75 - 37.5 * @sin(math.pi / 6.0 * i);

    context.transformation = context.transformation
        .translate(x_offset, y_offset)
        .rotate(math.pi / 6.0 * i)
        .scale(2, 1);
    var path = try z2d.Path.initCapacity(alloc, 0);
    defer path.deinit(alloc);
    path.transformation = context.transformation;
    try path.moveTo(alloc, 0, 0);
    try path.lineTo(alloc, 25, 75);
    try path.lineTo(alloc, 50, 0);
    context.line_width = lw: {
        var ux = saved_line_width;
        var uy = saved_line_width;
        try context.transformation.deviceToUserDistance(&ux, &uy);
        if (ux < uy) {
            break :lw uy;
        }
        break :lw ux;
    };
    try context.stroke(alloc, path);

    // Draw a hairline in red to help validate/measure
    context.pattern.opaque_pattern.pixel = .{ .rgb = .{ .r = 0xF3, .g = 0x00, .b = 0x00 } }; // Red
    context.line_width = 1;

    try context.stroke(alloc, path);
}
