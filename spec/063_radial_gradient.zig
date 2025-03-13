// SPDX-License-Identifier: 0BSD
//   Copyright © 2025 Chris Marchesi

//! Case: renders radial gradients in various patterns and edge/degenerate cases.
const math = @import("std").math;
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "063_radial_gradient";

pub fn render(alloc: mem.Allocator) !z2d.Surface {
    const width = 300;
    const height = 500;
    var dst_sfc = try z2d.Surface.init(.image_surface_rgba, alloc, width, height);

    // Test moving the focal point around with a bit of a center.
    for (0..3) |y| {
        for (0..3) |x| {
            try draw(
                alloc,
                &dst_sfc,
                100 * @as(i32, @intCast(x)),
                100 * @as(i32, @intCast(y)),
                49 + 25 * (@as(f64, @floatFromInt(x)) - 1),
                49 + 25 * (@as(f64, @floatFromInt(y)) - 1),
                5,
                49,
                49,
                50,
            );
        }
    }

    // Focal point in middle with no radius (so basic radial gradient)
    try draw(
        alloc,
        &dst_sfc,
        0,
        300,
        49,
        49,
        0,
        49,
        49,
        50,
    );

    // Reversed focal point
    try draw(
        alloc,
        &dst_sfc,
        100,
        300,
        49,
        49,
        50,
        49,
        49,
        0,
    );

    // Some edge cases (writes empty pixels in some or all areas)
    //
    // Identical radii
    try draw(
        alloc,
        &dst_sfc,
        200,
        300,
        49,
        49,
        50,
        49,
        49,
        50,
    );

    // Both radii zero
    try draw(
        alloc,
        &dst_sfc,
        0,
        400,
        49,
        49,
        0,
        49,
        49,
        0,
    );

    // Focal point outside of circle
    try draw(
        alloc,
        &dst_sfc,
        100,
        400,
        10,
        49,
        0,
        49,
        49,
        25,
    );

    // "Cylinder" effect (inner radius 1px smaller than outer)
    try draw(
        alloc,
        &dst_sfc,
        200,
        400,
        49,
        49,
        49,
        49,
        49,
        50,
    );

    return dst_sfc;
}

fn draw(
    alloc: mem.Allocator,
    dst_sfc: *z2d.Surface,
    sfc_x: i32,
    sfc_y: i32,
    inner_x: f64,
    inner_y: f64,
    inner_radius: f64,
    outer_x: f64,
    outer_y: f64,
    outer_radius: f64,
) !void {
    var scratch_sfc = try z2d.Surface.init(.image_surface_rgba, alloc, 100, 100);
    defer scratch_sfc.deinit(alloc);
    var stop_buffer: [3]z2d.gradient.Stop = undefined;
    var gradient = z2d.Gradient.init(.{
        .type = .{ .radial = .{
            .inner_x = inner_x,
            .inner_y = inner_y,
            .inner_radius = inner_radius,
            .outer_x = outer_x,
            .outer_y = outer_y,
            .outer_radius = outer_radius,
        } },
        .stops = &stop_buffer,
    });
    gradient.addStopAssumeCapacity(0, .{ .rgb = .{ 1, 0, 0 } });
    gradient.addStopAssumeCapacity(0.5, .{ .rgb = .{ 0, 1, 0 } });
    gradient.addStopAssumeCapacity(1, .{ .rgb = .{ 0, 0, 1 } });
    z2d.compositor.SurfaceCompositor.run(&scratch_sfc, 0, 0, 1, .{.{
        .operator = .src_over,
        .src = .{ .gradient = &gradient },
    }});
    dst_sfc.composite(&scratch_sfc, .src_over, sfc_x, sfc_y);
}
