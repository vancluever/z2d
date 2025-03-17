// SPDX-License-Identifier: 0BSD
//   Copyright © 2025 Chris Marchesi

//! Case: renders some linear gradients using lower-level compositing on
//! intermediary surfaces, in HSL space, using shorter path.
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "062_hsl_gradient";

pub fn render(alloc: mem.Allocator) !z2d.Surface {
    const width = 100;
    const height = 200;
    var dst_sfc = try z2d.Surface.init(.image_surface_rgb, alloc, width, height);

    // magenta to yellow, left to right.
    try draw(
        alloc,
        &dst_sfc,
        100,
        100,
        0,
        0,
        0,
        49,
        99,
        49,
        .{ .hsl = .{ 300, 1, 0.5 } },
        .{ .hsl = .{ 60, 1, 0.5 } },
    );

    // red to cyan, simulating the 0 degree - 180 degree cross-section of the
    // HSL bicone.
    try draw(
        alloc,
        &dst_sfc,
        50,
        100,
        0,
        100,
        0,
        49,
        49,
        49,
        .{ .hsl = .{ 0, 1, 0.5 } },
        .{ .hsl = .{ 0, 0, 0.5 } },
    );
    try draw(
        alloc,
        &dst_sfc,
        50,
        100,
        50,
        100,
        49,
        49,
        0,
        49,
        .{ .hsl = .{ 180, 1, 0.5 } },
        .{ .hsl = .{ 180, 0, 0.5 } },
    );
    try draw(
        alloc,
        &dst_sfc,
        100,
        50,
        0,
        100,
        49,
        0,
        49,
        49,
        .{ .hsla = .{ 0, 0, 1, 1 } },
        .{ .hsla = .{ 0, 0, 0.5, 0 } },
    );
    try draw(
        alloc,
        &dst_sfc,
        100,
        50,
        0,
        150,
        49,
        49,
        49,
        0,
        .{ .hsla = .{ 0, 0, 0, 1 } },
        .{ .hsla = .{ 0, 0, 0.5, 0 } },
    );

    return dst_sfc;
}

fn draw(
    alloc: mem.Allocator,
    dst_sfc: *z2d.Surface,
    width: i32,
    height: i32,
    sfc_x: i32,
    sfc_y: i32,
    linear_x0: f64,
    linear_y0: f64,
    linear_x1: f64,
    linear_y1: f64,
    c0: z2d.Color.InitArgs,
    c1: z2d.Color.InitArgs,
) !void {
    var scratch_sfc = try z2d.Surface.init(.image_surface_rgba, alloc, width, height);
    defer scratch_sfc.deinit(alloc);
    var stop_buffer: [2]z2d.gradient.Stop = undefined;
    var gradient = z2d.Gradient.init(.{
        .type = .{ .linear = .{
            .x0 = linear_x0,
            .y0 = linear_y0,
            .x1 = linear_x1,
            .y1 = linear_y1,
        } },
        .stops = &stop_buffer,
        .method = .{ .hsl = .shorter },
    });
    gradient.addStopAssumeCapacity(0, c0);
    gradient.addStopAssumeCapacity(1, c1);
    z2d.compositor.SurfaceCompositor.run(&scratch_sfc, 0, 0, 1, .{.{
        .operator = .src_over,
        .src = .{ .gradient = &gradient },
    }}, .{});
    dst_sfc.composite(&scratch_sfc, .src_over, sfc_x, sfc_y, .{});
}
