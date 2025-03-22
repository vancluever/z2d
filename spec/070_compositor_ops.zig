// SPDX-License-Identifier: 0BSD
//   Copyright © 2025 Chris Marchesi

//! Testing for all the supported operators.
//!
//! Operators are run in their enumeration order so the enum can be consulted
//! for each operator name. Each column represents: integer, (fully opaque, and
//! then with alpha), then float, (fully opaque, then alpha). Note that the
//! compositor will automatically switch to floating point precision for
//! operators that are not supported by integer precision.
const math = @import("std").math;
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "070_compositor_ops";

pub fn render(alloc: mem.Allocator, aa_mode: z2d.options.AntiAliasMode) !z2d.Surface {
    const width = 460;
    const height = 3090;
    var sfc = try z2d.Surface.initPixel(
        z2d.pixel.RGB.fromPixel(z2d.Pixel.fromColor(.{ .rgb = .{ 1, 1, 1 } })).asPixel(),
        alloc,
        width,
        height,
    );

    inline for (@typeInfo(z2d.compositor.Operator).Enum.fields, 0..) |op, i| {
        for (0..2) |j| {
            try draw(
                alloc,
                &sfc,
                @intCast(10 + 110 * j),
                @intCast(10 + 110 * i),
                @enumFromInt(op.value),
                .integer,
                aa_mode,
                @bitCast(@as(u1, @intCast(j))),
            );
        }
        for (2..4) |j| {
            try draw(
                alloc,
                &sfc,
                @intCast(10 + 110 * j),
                @intCast(10 + 110 * i),
                @enumFromInt(op.value),
                .float,
                aa_mode,
                @bitCast(@as(u1, @intCast(j % 2))),
            );
        }
    }

    return sfc;
}

fn draw(
    alloc: mem.Allocator,
    main_sfc: *z2d.Surface,
    sfc_x: i32,
    sfc_y: i32,
    op: z2d.compositor.Operator,
    precision: z2d.compositor.Precision,
    aa_mode: z2d.options.AntiAliasMode,
    transparent: bool,
) !void {
    const bg: z2d.Pixel = if (transparent)
        z2d.Pixel.fromColor(.{ .rgba = .{ 0.69, 0.23, 0.21, 0.9 } })
    else
        z2d.Pixel.fromColor(.{ .rgb = .{ 0.69, 0.23, 0.21 } });

    const fg: z2d.Pixel = if (transparent)
        z2d.Pixel.fromColor(.{ .rgba = .{ 0.56, 0.50, 0.89, 0.8 } })
    else
        z2d.Pixel.fromColor(.{ .rgb = .{ 0.56, 0.50, 0.89 } });

    var scratch_sfc = try z2d.Surface.init(.image_surface_rgba, alloc, 100, 100);
    defer scratch_sfc.deinit(alloc);

    var context = z2d.Context.init(alloc, &scratch_sfc);
    defer context.deinit();
    context.setAntiAliasingMode(aa_mode);
    context.setPrecision(precision);
    context.setSourceToPixel(bg);
    try context.moveTo(0, 0);
    try context.lineTo(75, 0);
    try context.lineTo(75, 75);
    try context.lineTo(0, 75);
    try context.closePath();
    try context.fill();

    context.setSourceToPixel(fg);
    context.setOperator(op);
    context.resetPath();
    context.translate(25, 25);
    try context.moveTo(0, 0);
    try context.lineTo(75, 0);
    try context.lineTo(75, 75);
    try context.lineTo(0, 75);
    try context.closePath();
    try context.fill();

    main_sfc.composite(&scratch_sfc, .src_over, sfc_x, sfc_y, .{});
}
