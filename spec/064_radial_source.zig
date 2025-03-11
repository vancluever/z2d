// SPDX-License-Identifier: 0BSD
//   Copyright © 2025 Chris Marchesi

//! Case: basic radial gradient rendering to validate functionality in the
//! painter.
const math = @import("std").math;
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "064_radial_source";

pub fn render(alloc: mem.Allocator, aa_mode: z2d.options.AntiAliasMode) !z2d.Surface {
    const width = 100;
    const height = 100;
    var sfc = try z2d.Surface.init(.image_surface_rgb, alloc, width, height);
    var stop_buffer: [3]z2d.gradient.Stop = undefined;
    var gradient = z2d.Gradient.init(.{
        .type = .{ .radial = .{
            .inner_x = 49,
            .inner_y = 49,
            .inner_radius = 0,
            .outer_x = 49,
            .outer_y = 49,
            .outer_radius = 50,
        } },
        .stops = &stop_buffer,
    });
    gradient.addStopAssumeCapacity(0, .{ .rgb = .{ 1, 0, 0 } });
    gradient.addStopAssumeCapacity(0.5, .{ .rgb = .{ 0, 1, 0 } });
    gradient.addStopAssumeCapacity(1, .{ .rgb = .{ 0, 0, 1 } });
    var context = try z2d.Context.init(alloc, &sfc);
    defer context.deinit();
    context.setAntiAliasingMode(aa_mode);
    context.setSource(gradient.asPattern());
    try context.moveTo(0, 0);
    try context.lineTo(100, 0);
    try context.lineTo(100, 100);
    try context.lineTo(0, 100);
    try context.closePath();
    try context.fill();

    return sfc;
}
