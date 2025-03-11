// SPDX-License-Identifier: 0BSD
//   Copyright © 2025 Chris Marchesi

//! Demonstrates removal of gradient banding by adding dither. The top gradient
//! is rendered without dithering, the below one is rendered with it, which
//! visibly removes it.
const math = @import("std").math;
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "068_gradient_deband";

pub fn render(alloc: mem.Allocator) !z2d.Surface {
    const width = 500;
    const height = 500;
    var dst_sfc = try z2d.Surface.initPixel(
        // Explicit cast to RGB from the normal RGBA that fromColor gives.
        z2d.pixel.RGB.fromPixel(z2d.Pixel.fromColor(.{ .rgb = .{ 1, 1, 1 } })).asPixel(),
        alloc,
        width,
        height,
    );

    // Draw 5 gradient areas. The first two is a color demo on 8 bit, first
    // non-dithered, second dithered (you may need to disable any
    // AA/blur/smoothing to see the banding, and funny enough, the dither
    // effect). The last 3 demonstrate grayscale; the first is non-dithered
    // 8-bit, then non-dithered 4-bit, then dithered 4-bit.
    try draw(alloc, &dst_sfc, 0, 0, false, 8, .none);
    try draw(alloc, &dst_sfc, 0, 100, false, 8, .bayer);
    try draw(alloc, &dst_sfc, 0, 200, true, 8, .none);
    try draw(alloc, &dst_sfc, 0, 300, true, 4, .none);
    try draw(alloc, &dst_sfc, 0, 400, true, 4, .bayer);

    return dst_sfc;
}

fn draw(
    alloc: mem.Allocator,
    dst_sfc: *z2d.Surface,
    sfc_x: i32,
    sfc_y: i32,
    grayscale: bool,
    bits: u4,
    dither: z2d.compositor.Dither.Type,
) !void {
    var scratch_sfc: z2d.Surface = try z2d.Surface.init(switch (grayscale) {
        true => switch (bits) {
            4 => .image_surface_alpha4,
            else => .image_surface_alpha8,
        },
        false => .image_surface_rgb,
    }, alloc, 500, 100);
    defer scratch_sfc.deinit(alloc);
    var stop_buffer: [2]z2d.gradient.Stop = undefined;
    var gradient = z2d.Gradient.init(.{
        .type = .{ .linear = .{
            .x0 = 0,
            .y0 = 50,
            .x1 = 500,
            .y1 = 50,
        } },
        .stops = &stop_buffer,
    });
    if (grayscale) {
        // NOTE: We're not doing true grayscale here, since we're trying to
        // demonstrate the effect of gradients on lower bit-depth surfaces, of
        // which we only support alpha versions at time of this writing (these
        // export to grayscale so if you were compositing to an alpha surface
        // and then exporting that would work as expected). So what we do is
        // start from white (transparent, which shows white as well since
        // that's what we have on the main surface) to opaque black.
        gradient.addStopAssumeCapacity(0, .{ .rgba = .{ 1, 1, 1, 0 } });
        gradient.addStopAssumeCapacity(1, .{ .rgba = .{ 0, 0, 0, 1 } });
    } else {
        gradient.addStopAssumeCapacity(0, .{ .rgb = .{ 27.0 / 255.0, 93.0 / 255.0, 124.0 / 255.0 } });
        gradient.addStopAssumeCapacity(1, .{ .rgb = .{ 38.0 / 255.0, 32.0 / 255.0, 16.0 / 255.0 } });
    }
    z2d.compositor.SurfaceCompositor.run(&scratch_sfc, 0, 0, 1, .{.{
        .operator = .over,
        .src = .{
            .dither = .{
                .type = dither,
                .source = .{ .gradient = &gradient },
                .scale = bits,
            },
        },
    }});
    dst_sfc.composite(&scratch_sfc, .over, sfc_x, sfc_y);
}
