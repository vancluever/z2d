// SPDX-License-Identifier: 0BSD
//   Copyright © 2024-2025 Chris Marchesi

//! Case: Covers clip cases for hairline stroking.
const math = @import("std").math;
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "082_stroke_hairline_clip";

pub fn render(alloc: mem.Allocator, aa_mode: z2d.options.AntiAliasMode) !z2d.Surface {
    const width = 200;
    const height = cases.len / 2 * 100;
    var sfc = try z2d.Surface.init(.image_surface_rgb, alloc, width, height);
    for (0..cases.len) |idx| {
        try renderCase(alloc, aa_mode, &sfc, idx);
    }

    return sfc;
}

fn renderCase(
    alloc: mem.Allocator,
    aa_mode: z2d.options.AntiAliasMode,
    dst_sfc: *z2d.Surface,
    idx: usize,
) !void {
    // on = if index / 2 (row) is odd and index % 2 (column) is 1
    //   OR if index / 2 (row) is even and index % 2 (column) is 0
    const on: u8 = 0x20 * @as(u8, @intCast(idx / 2 & 1 ^ (idx % 2)));
    const background: z2d.Pixel = .{ .rgb = .{ .r = on, .g = on, .b = on } };
    var src_sfc = try z2d.Surface.initPixel(background, alloc, 100, 100);
    defer src_sfc.deinit(alloc);
    const pattern: z2d.Pattern = .{
        .opaque_pattern = .{ .pixel = .{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } } },
    };
    var path: z2d.StaticPath(2) = undefined;
    path.init();
    path.moveTo(@floatFromInt(cases[idx].x0), @floatFromInt(cases[idx].y0));
    path.lineTo(@floatFromInt(cases[idx].x1), @floatFromInt(cases[idx].y1));
    try z2d.painter.stroke(
        alloc,
        &src_sfc,
        &pattern,
        &path.nodes,
        .{ .anti_aliasing_mode = aa_mode, .hairline = true },
    );
    z2d.compositor.SurfaceCompositor.run(dst_sfc, @intCast(idx % 2 * 100), @intCast(idx / 2 * 100), 1, .{
        .{
            .operator = .src,
            .src = .{ .surface = &src_sfc },
        },
    }, .{});
}

const cases = [_]struct {
    // on a 100x100 canvas
    x0: i32,
    y0: i32,
    x1: i32,
    y1: i32,
}{
    .{
        // major x, clipped left
        .x0 = -25,
        .y0 = 50,
        .x1 = 75,
        .y1 = 60,
    },
    .{
        // major x, clipped right
        .x0 = 25,
        .y0 = 50,
        .x1 = 125,
        .y1 = 60,
    },
    .{
        // major x (fully horizontal), clipped left
        .x0 = -25,
        .y0 = 50,
        .x1 = 75,
        .y1 = 50,
    },
    .{
        // major x (fully horizontal), clipped right
        .x0 = 25,
        .y0 = 50,
        .x1 = 125,
        .y1 = 50,
    },
    .{
        // major x, clipped top
        .x0 = 25,
        .y0 = -50,
        .x1 = 75,
        .y1 = 50,
    },
    .{
        // major x, clipped bottom
        .x0 = 25,
        .y0 = 50,
        .x1 = 75,
        .y1 = 150,
    },
    .{
        // major x, completely OOB (upper left)
        .x0 = -25,
        .y0 = -50,
        .x1 = -75,
        .y1 = -150,
    },
    .{
        // major x, completely OOB (bottom right)
        .x0 = 125,
        .y0 = 150,
        .x1 = 175,
        .y1 = 250,
    },
    .{
        // major y, clipped top
        .x0 = 50,
        .y0 = -25,
        .x1 = 60,
        .y1 = 75,
    },
    .{
        // major y, clipped bottom
        .x0 = 50,
        .y0 = 25,
        .x1 = 60,
        .y1 = 125,
    },
    .{
        // major y (completely vertical), clipped top
        .x0 = 50,
        .y0 = -25,
        .x1 = 50,
        .y1 = 75,
    },
    .{
        // major y (completely vertical), clipped bottom
        .x0 = 50,
        .y0 = 25,
        .x1 = 50,
        .y1 = 125,
    },
    .{
        // major y, clipped left
        .x0 = -50,
        .y0 = 25,
        .x1 = 50,
        .y1 = 75,
    },
    .{
        // major y, clipped right
        .x0 = 50,
        .y0 = 25,
        .x1 = 150,
        .y1 = 75,
    },
    .{
        // major y, completely OOB (upper left)
        .x0 = -50,
        .y0 = -25,
        .x1 = -150,
        .y1 = -75,
    },
    .{
        // major y, completely OOB (bottom right)
        .x0 = 150,
        .y0 = 125,
        .x1 = 250,
        .y1 = 175,
    },
};
