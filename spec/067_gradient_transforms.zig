// SPDX-License-Identifier: 0BSD
//   Copyright © 2025 Chris Marchesi

//! Draws gradients with transformations set.
const math = @import("std").math;
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "067_gradient_transforms";

pub fn render(alloc: mem.Allocator, aa_mode: z2d.options.AntiAliasMode) !z2d.Surface {
    const width = 200;
    const height = 200;
    var sfc = try z2d.Surface.init(.image_surface_rgb, alloc, width, height);
    var linear = z2d.Gradient.init(.{ .type = .{ .linear = .{
        .x0 = 0,
        .y0 = 0,
        .x1 = 50,
        .y1 = 50,
    } } });
    defer linear.deinit(alloc);
    try linear.addStop(alloc, 0, .{ .rgb = .{ 1, 0, 0 } });
    try linear.addStop(alloc, 0.5, .{ .rgb = .{ 0, 1, 0 } });
    try linear.addStop(alloc, 1, .{ .rgb = .{ 0, 0, 1 } });
    var context = try z2d.Context.init(alloc, &sfc);
    defer context.deinit();
    context.scale(2, 2);
    context.setAntiAliasingMode(aa_mode);
    context.setSource(linear.asPattern());
    try context.moveTo(0, 0);
    try context.lineTo(50, 0);
    try context.lineTo(50, 50);
    try context.lineTo(0, 50);
    try context.closePath();
    try context.fill();

    var radial = z2d.Gradient.init(.{
        .type = .{ .radial = .{
            .inner_x = 25,
            .inner_y = 50,
            .inner_radius = 0,
            .outer_x = 25,
            .outer_y = 50,
            .outer_radius = 50,
        } },
    });
    defer radial.deinit(alloc);
    try radial.addStop(alloc, 0, .{ .rgb = .{ 1, 0, 0 } });
    try radial.addStop(alloc, 0.5, .{ .rgb = .{ 0, 1, 0 } });
    try radial.addStop(alloc, 1, .{ .rgb = .{ 0, 0, 1 } });
    context.setIdentity();
    var skew = z2d.Transformation.identity;
    skew.by = 0.5;
    context.mul(skew);
    context.translate(100, 0);
    context.setSource(radial.asPattern());
    context.setIdentity();
    context.translate(100, 0);
    context.resetPath();
    try context.moveTo(0, 0);
    try context.lineTo(100, 0);
    try context.lineTo(100, 100);
    try context.lineTo(0, 100);
    try context.closePath();
    try context.fill();

    var conic = z2d.Gradient.init(.{
        .type = .{ .conic = .{
            .x = 50,
            .y = 50,
            .angle = 0,
        } },
        .method = .{ .hsl = .increasing },
    });
    defer conic.deinit(alloc);
    try conic.addStop(alloc, 0, .{ .hsl = .{ 0, 1, 0.5 } });
    try conic.addStop(alloc, 1, .{ .hsl = .{ 360, 1, 0.5 } });
    context.setIdentity();
    context.scale(2, 1);
    context.translate(0, 100);
    context.setSource(conic.asPattern());
    context.resetPath();
    try context.moveTo(0, 0);
    try context.lineTo(100, 0);
    try context.lineTo(100, 100);
    try context.lineTo(0, 100);
    try context.closePath();
    try context.fill();

    return sfc;
}
