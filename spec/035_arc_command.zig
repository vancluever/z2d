// SPDX-License-Identifier: W3C-20150513

//! Case: Renders arcs with native commands.
//!
//! The pie diagram demonstration has been taken from the SVG spec. It includes
//! material copied from or derived from
//! https://www.w3.org/TR/SVG11/paths.html#PathDataEllipticalArcCommands.
//! Copyright © 2011 World Wide Web Consortium.
//! https://www.w3.org/copyright/software-license-2023/
const math = @import("std").math;
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "035_arc_command";

pub fn render(alloc: mem.Allocator, aa_mode: z2d.options.AntiAliasMode) !z2d.Surface {
    const width = 400;
    const height = 400;
    const sfc = try z2d.Surface.initPixel(
        .{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } }, // White
        alloc,
        width,
        height,
    );

    var context: z2d.Context = .{
        .surface = sfc,
        .pattern = .{
            .opaque_pattern = .{
                .pixel = .{ .rgb = .{ .r = 0xFF, .g = 0x00, .b = 0x00 } }, // Red for our initial draw
            },
        },
        .anti_aliasing_mode = aa_mode,
        .line_width = 5,
    };

    var path = try z2d.Path.initCapacity(alloc, 0);
    defer path.deinit(alloc);
    try path.moveTo(alloc, 200, 200);
    try path.arcNegative(alloc, 200, 200, 150, math.pi, math.pi * 1.5);
    try path.close(alloc);
    try context.fill(alloc, path);
    context.pattern = .{
        .opaque_pattern = .{
            .pixel = .{ .rgb = .{ .r = 0x00, .g = 0x00, .b = 0xFF } }, // Blue for stroke
        },
    };
    try context.stroke(alloc, path);

    path.reset();
    try path.moveTo(alloc, 175, 175);
    try path.arc(alloc, 175, 175, 150, math.pi, math.pi * 1.5);
    try path.close(alloc);
    context.pattern = .{
        .opaque_pattern = .{
            .pixel = .{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0x00 } }, // Yellow for fill
        },
    };
    try context.fill(alloc, path);
    context.pattern = .{
        .opaque_pattern = .{
            .pixel = .{ .rgb = .{ .r = 0x00, .g = 0x00, .b = 0xFF } }, // Blue for stroke
        },
    };
    try context.stroke(alloc, path);

    return sfc;
}
