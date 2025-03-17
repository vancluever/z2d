// SPDX-License-Identifier: 0BSD
//   Copyright © 2024 Chris Marchesi

//! Case: renders some linear gradients using lower-level compositing on
//! intermediary surfaces.
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "061_linear_gradient";

pub fn render(alloc: mem.Allocator) !z2d.Surface {
    const width = 200;
    const height = 400;
    var dst_sfc = try z2d.Surface.init(.image_surface_rgb, alloc, width, height);
    var scratch_sfc = try z2d.Surface.init(.image_surface_rgb, alloc, 100, 100);
    defer scratch_sfc.deinit(alloc);

    // Left to right
    draw(&dst_sfc, &scratch_sfc, 0, 0, 0, 49, 99, 49);

    // Right to left
    draw(&dst_sfc, &scratch_sfc, 100, 0, 99, 49, 0, 49);

    // Top -> bottom
    draw(&dst_sfc, &scratch_sfc, 0, 100, 49, 0, 49, 99);

    // Bottom -> top
    draw(&dst_sfc, &scratch_sfc, 100, 100, 49, 99, 49, 0);

    // UL -> BR
    draw(&dst_sfc, &scratch_sfc, 0, 200, 0, 0, 99, 99);

    // UR -> BL
    draw(&dst_sfc, &scratch_sfc, 100, 200, 99, 0, 0, 99);

    // BL -> UR
    draw(&dst_sfc, &scratch_sfc, 0, 300, 0, 99, 99, 0);

    // BR -> UL
    draw(&dst_sfc, &scratch_sfc, 100, 300, 99, 99, 0, 0);

    return dst_sfc;
}

fn draw(
    dst_sfc: *z2d.Surface,
    scratch_sfc: *z2d.Surface,
    sfc_x: i32,
    sfc_y: i32,
    linear_x0: f64,
    linear_y0: f64,
    linear_x1: f64,
    linear_y1: f64,
) void {
    var stop_buffer: [3]z2d.gradient.Stop = undefined;
    var gradient = z2d.Gradient.init(.{
        .type = .{ .linear = .{
            .x0 = linear_x0,
            .y0 = linear_y0,
            .x1 = linear_x1,
            .y1 = linear_y1,
        } },
        .stops = &stop_buffer,
    });
    gradient.addStopAssumeCapacity(0, .{ .rgb = .{ 1, 0, 0 } });
    gradient.addStopAssumeCapacity(0.5, .{ .rgb = .{ 0, 1, 0 } });
    gradient.addStopAssumeCapacity(1, .{ .rgb = .{ 0, 0, 1 } });
    z2d.compositor.SurfaceCompositor.run(scratch_sfc, 0, 0, 1, .{.{
        .operator = .src_over,
        .src = .{ .gradient = &gradient },
    }}, .{});
    dst_sfc.composite(scratch_sfc, .src_over, sfc_x, sfc_y, .{});
}
