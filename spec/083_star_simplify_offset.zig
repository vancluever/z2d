// SPDX-License-Identifier: 0BSD
//   Copyright © 2024-2026 Chris Marchesi

//! Case: Takes our self-intersecting star example and demonstrates how one can
//! use the path simplification functionality to remove the self-intersections.
//! We then demonstrate offset functionality by drawing repeated insets of the
//! star.
const Io = @import("std").Io;
const math = @import("std").math;
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "083_star_simplify_offset";

const width = 300;
const canvas_height = 1200;
const draw_height = 300;

pub fn render(io: Io, alloc: mem.Allocator, aa_mode: z2d.options.AntiAliasMode) !z2d.Surface {
    var sfc = try z2d.Surface.init(.image_surface_rgb, alloc, width, canvas_height);
    var context = z2d.Context.init(io, alloc, &sfc);
    defer context.deinit();
    context.setSourceToPixel(.{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } });
    context.setAntiAliasingMode(aa_mode);

    // The initial path
    try setPathStar(&context);
    try context.stroke();

    // The simplified path
    context.translate(0, 300);
    try setPathStar(&context);
    try context.simplifyPath();
    try context.stroke();

    // Inset fill at steps of 7.5px at a time, stepping on the HSL color wheel.
    // Add stroke for legibility (the green and yellow can be hard to
    // distinguish apart).
    context.setIdentity();
    context.translate(0, 600);
    try setPathStar(&context);
    try context.simplifyPath();
    {
        const offset: f64 = -7.5;
        const steps = 5;
        for (0..steps) |step| {
            const hue: f32 = 360.0 / steps * @as(f32, @floatFromInt(step));
            context.setSourceToPixel(z2d.Pixel.fromColor(.{ .hsl = .{ hue, 1.0, 0.5 } }));
            if (step != 0) {
                try context.offsetPath(offset);
            }
            try context.fill();
            if (step != 0) {
                context.setSourceToPixel(.{ .rgb = .{ .r = 0x00, .g = 0x00, .b = 0x00 } });
                try context.stroke();
            }
        }
    }

    // Outset test, we start in the middle with an arc and expand outward, same
    // color wheel, just in reverse, and with more steps and a bigger offset.
    context.setIdentity();
    context.translate(0, 900);
    context.setLineWidth(8.0);
    try setPathArc(&context);
    {
        const offset: f64 = 10.5;
        const steps = 10;
        for (0..steps) |step| {
            const hue: f32 = 360.0 / steps * @as(f32, @floatFromInt(step));
            context.setSourceToPixel(z2d.Pixel.fromColor(.{ .hsl = .{ hue, 1.0, 0.5 } }));
            if (step != 0) {
                try context.offsetPath(offset);
            }
            try context.stroke();
        }
    }

    return sfc;
}

fn setPathStar(context: *z2d.Context) !void {
    // With all 5 points numbered 1-5 clockwise, we draw odds first (1, 3, 5),
    // then evens (4, 2), with the close connecting 4 and 1.
    const margin = 20;
    const x_scale = 3;
    const y_scale = 5;
    context.resetPath();
    try context.moveTo(width / 2, 0 + margin); // 1
    try context.lineTo(width - margin * x_scale - 1, draw_height - margin - 1); // 3
    try context.lineTo(0 + margin, 0 + margin * y_scale); // 5
    try context.lineTo(width - margin - 1, 0 + margin * y_scale); // 2
    try context.lineTo(0 + margin * x_scale, draw_height - margin - 1); // 4
    try context.closePath();
}

fn setPathArc(context: *z2d.Context) !void {
    const radius = width / 15;
    const x = width / 2;
    const y = draw_height / 2;
    context.resetPath();
    const saved_ctm = context.getTransformation();
    defer context.setTransformation(saved_ctm);
    context.translate(x, y);
    context.scale(radius, radius);
    try context.arc(0, 0, 1, 0, 2 * math.pi);
    try context.closePath();
}
