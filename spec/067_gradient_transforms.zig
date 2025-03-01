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
    var linear = z2d.gradient.Linear.init(
        0,
        0,
        50,
        50,
        .linear_rgb,
    );
    defer linear.deinit(alloc);
    try linear.stops.add(alloc, 0, .{ .rgb = .{ 1, 0, 0 } });
    try linear.stops.add(alloc, 0.5, .{ .rgb = .{ 0, 1, 0 } });
    try linear.stops.add(alloc, 1, .{ .rgb = .{ 0, 0, 1 } });
    var context = try z2d.Context.init(alloc, &sfc);
    defer context.deinit();
    context.scale(2, 2);
    context.setAntiAliasingMode(aa_mode);
    context.setSource(linear.asPatternInterface());
    try context.moveTo(0, 0);
    try context.lineTo(50, 0);
    try context.lineTo(50, 50);
    try context.lineTo(0, 50);
    try context.closePath();
    try context.fill();

    var radial = z2d.gradient.Radial.init(
        25,
        50,
        0,
        25,
        50,
        50,
        .linear_rgb,
    );
    defer radial.deinit(alloc);
    try radial.stops.add(alloc, 0, .{ .rgb = .{ 1, 0, 0 } });
    try radial.stops.add(alloc, 0.5, .{ .rgb = .{ 0, 1, 0 } });
    try radial.stops.add(alloc, 1, .{ .rgb = .{ 0, 0, 1 } });
    context.setIdentity();
    var skew = z2d.Transformation.identity;
    skew.by = 0.5;
    context.mul(skew);
    context.translate(100, 0);
    context.setSource(radial.asPatternInterface());
    context.setIdentity();
    context.translate(100, 0);
    context.resetPath();
    try context.moveTo(0, 0);
    try context.lineTo(100, 0);
    try context.lineTo(100, 100);
    try context.lineTo(0, 100);
    try context.closePath();
    try context.fill();

    var conic = z2d.gradient.Conic.init(
        50,
        50,
        0,
        .{ .hsl = .increasing },
    );
    defer conic.deinit(alloc);
    try conic.stops.add(alloc, 0, .{ .hsl = .{ 0, 1, 0.5 } });
    try conic.stops.add(alloc, 1, .{ .hsl = .{ 360, 1, 0.5 } });
    context.setIdentity();
    context.scale(2, 1);
    context.translate(0, 100);
    context.setSource(conic.asPatternInterface());
    context.resetPath();
    try context.moveTo(0, 0);
    try context.lineTo(100, 0);
    try context.lineTo(100, 100);
    try context.lineTo(0, 100);
    try context.closePath();
    try context.fill();

    return sfc;
}
