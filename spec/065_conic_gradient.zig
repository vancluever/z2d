// SPDX-License-Identifier: 0BSD
//   Copyright © 2025 Chris Marchesi

//! Case: renders conic gradients.
const math = @import("std").math;
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "065_conic_gradient";

pub fn render(alloc: mem.Allocator) !z2d.Surface {
    const width = 200;
    const height = 200;
    var dst_sfc = try z2d.Surface.init(.image_surface_rgba, alloc, width, height);

    for (0..2) |y| {
        for (0..2) |x| {
            try draw(
                alloc,
                &dst_sfc,
                100 * @as(i32, @intCast(x)),
                100 * @as(i32, @intCast(y)),
                49,
                49,
                math.pi / 2.0 * @as(f64, @floatFromInt(y * 2 + x)),
            );
        }
    }

    return dst_sfc;
}

fn draw(
    alloc: mem.Allocator,
    dst_sfc: *z2d.Surface,
    sfc_x: i32,
    sfc_y: i32,
    center_x: f64,
    center_y: f64,
    angle: f64,
) !void {
    var scratch_sfc = try z2d.Surface.init(.image_surface_rgba, alloc, 100, 100);
    defer scratch_sfc.deinit(alloc);
    var stop_buffer: [2]z2d.gradient.Stop = undefined;
    var gradient = z2d.Gradient.init(.{
        .type = .{ .conic = .{
            .x = center_x,
            .y = center_y,
            .angle = angle,
        } },
        .stops = &stop_buffer,
        .method = .{ .hsl = .increasing },
    });
    gradient.addStopAssumeCapacity(0, .{ .hsl = .{ 0, 1, 0.5 } });
    gradient.addStopAssumeCapacity(1, .{ .hsl = .{ 360, 1, 0.5 } });
    z2d.compositor.SurfaceCompositor.run(&scratch_sfc, 0, 0, 1, .{.{
        .operator = .src_over,
        .src = .{ .gradient = &gradient },
    }});
    dst_sfc.composite(&scratch_sfc, .src_over, sfc_x, sfc_y);
}
