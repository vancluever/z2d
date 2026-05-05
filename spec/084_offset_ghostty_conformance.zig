// SPDX-License-Identifier: MIT
//   Copyright © 2024-2026 Chris Marchesi
//   Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors

//! Case: Conformance testing for offset stuff that is currently implemented in
//! ghostty via workarounds. Left column is drawn with the workaround, right
//! column is drawn using an offset path.
//!
//! Some relevant code taken from Ghostty (innerStrokePath and specific glyph
//! draw functions), and used under the terms of the MIT license. Below is a
//! copy of the MIT license.
//!
//! MIT License
//!
//! Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors
//!
//! Permission is hereby granted, free of charge, to any person obtaining a copy
//! of this software and associated documentation files (the "Software"), to deal
//! in the Software without restriction, including without limitation the rights
//! to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//! copies of the Software, and to permit persons to whom the Software is
//! furnished to do so, subject to the following conditions:
//!
//! The above copyright notice and this permission notice shall be included in all
//! copies or substantial portions of the Software.
//!
//! THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//! IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//! FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//! AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//! LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//! OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//! SOFTWARE.
const Io = @import("std").Io;
const math = @import("std").math;
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "084_offset_ghostty_conformance";

const canvas_width = 200;
const canvas_height = 1000;
const sub_canvas_width = 100;
const sub_canvas_height = 200;
const box_thickness = 10;

pub fn render(io: Io, alloc: mem.Allocator, aa_mode: z2d.options.AntiAliasMode) !z2d.Surface {
    var sfc = try z2d.Surface.init(.image_surface_alpha8, alloc, canvas_width, canvas_height);
    var context = z2d.Context.init(io, alloc, &sfc);
    defer context.deinit();

    try strokePathWorkaround(drawE0B5, alloc, &sfc, aa_mode, 0, 0);
    try strokePathNormal(drawE0B5, alloc, &sfc, aa_mode, 100, 0);

    try strokePathWorkaround(draw25F8, alloc, &sfc, aa_mode, 0, 200);
    try strokePathNormal(draw25F8, alloc, &sfc, aa_mode, 100, 200);

    try strokePathWorkaround(draw25F9, alloc, &sfc, aa_mode, 0, 400);
    try strokePathNormal(draw25F9, alloc, &sfc, aa_mode, 100, 400);

    try strokePathWorkaround(draw25FA, alloc, &sfc, aa_mode, 0, 600);
    try strokePathNormal(draw25FA, alloc, &sfc, aa_mode, 100, 600);

    try strokePathWorkaround(draw25FF, alloc, &sfc, aa_mode, 0, 800);
    try strokePathNormal(draw25FF, alloc, &sfc, aa_mode, 100, 800);

    return sfc;
}

/// Adapted from innerStrokePath from Ghostty.
fn strokePathWorkaround(
    pathFunc: *const fn (alloc: mem.Allocator, width: f64, height: f64, offset: f64) DrawPathError!z2d.Path,
    alloc: mem.Allocator,
    dst_sfc: *z2d.Surface,
    aa_mode: z2d.options.AntiAliasMode,
    dst_x: i32,
    dst_y: i32,
) !void {
    const fill_opts: z2d.painter.FillOptions = .{ .anti_aliasing_mode = aa_mode };
    const stroke_opts: z2d.painter.StrokeOptions = .{ .anti_aliasing_mode = aa_mode, .line_width = box_thickness };
    var path = try pathFunc(alloc, sub_canvas_width, sub_canvas_height, 0);
    defer path.deinit(alloc);

    // On one surface we fill the shape, this will be a mask we
    // multiply with the double-width stroke so that only the
    // part inside is used.
    var fill_sfc: z2d.Surface = try .init(
        .image_surface_alpha8,
        alloc,
        sub_canvas_width,
        sub_canvas_height,
    );
    defer fill_sfc.deinit(alloc);

    // On the other we'll do the double width stroke.
    var stroke_sfc: z2d.Surface = try .init(
        .image_surface_alpha8,
        alloc,
        sub_canvas_width,
        sub_canvas_height,
    );
    defer stroke_sfc.deinit(alloc);

    // Make a closed version of the path for our fill, so
    // that we can support open paths for inner stroke.
    var closed_path = path;
    closed_path.nodes = try path.nodes.clone(alloc);
    defer closed_path.deinit(alloc);
    try closed_path.close(alloc);

    // Fill the shape in white to the fill surface, we use
    // white because this is a mask that we'll multiply with
    // the stroke, we want everything inside to be the stroke
    // color.
    try z2d.painter.fill(
        alloc,
        &fill_sfc,
        &.{ .opaque_pattern = .{
            .pixel = .{ .alpha8 = .{ .a = 255 } },
        } },
        closed_path.nodes.items,
        fill_opts,
    );

    // Stroke the shape with double the desired width.
    var mut_opts = stroke_opts;
    mut_opts.line_width *= 2;
    try z2d.painter.stroke(
        alloc,
        &stroke_sfc,
        &.{ .opaque_pattern = .{
            .pixel = .{ .alpha8 = .{ .a = 255 } },
        } },
        path.nodes.items,
        mut_opts,
    );

    // We multiply the stroke sfc on to the fill surface.
    // The z2d composite operation doesn't seem to work for
    // this with alpha8 surfaces, so we have to do it manually.
    for (
        mem.sliceAsBytes(fill_sfc.image_surface_alpha8.buf),
        mem.sliceAsBytes(stroke_sfc.image_surface_alpha8.buf),
    ) |*d, s| {
        d.* = @intFromFloat(@round(
            255.0 *
                (@as(f64, @floatFromInt(s)) / 255.0) *
                (@as(f64, @floatFromInt(d.*)) / 255.0),
        ));
    }

    // Then we composite the result on to the main surface.
    dst_sfc.composite(&fill_sfc, .src_over, dst_x, dst_y, .{});
}

fn strokePathNormal(
    pathFunc: *const fn (alloc: mem.Allocator, width: f64, height: f64, offset: f64) DrawPathError!z2d.Path,
    alloc: mem.Allocator,
    dst_sfc: *z2d.Surface,
    aa_mode: z2d.options.AntiAliasMode,
    dst_x: i32,
    dst_y: i32,
) !void {
    var path = try pathFunc(alloc, sub_canvas_width, sub_canvas_height, -box_thickness / 2.0);
    defer path.deinit(alloc);

    var draw_sfc: z2d.Surface = try .init(
        .image_surface_alpha8,
        alloc,
        sub_canvas_width,
        sub_canvas_height,
    );
    defer draw_sfc.deinit(alloc);

    try z2d.painter.stroke(
        alloc,
        &draw_sfc,
        &.{ .opaque_pattern = .{
            .pixel = .{ .alpha8 = .{ .a = 255 } },
        } },
        path.nodes.items,
        .{ .anti_aliasing_mode = aa_mode, .line_width = box_thickness },
    );

    dst_sfc.composite(&draw_sfc, .src_over, dst_x, dst_y, .{});
}

const DrawPathError = z2d.Path.Error || mem.Allocator.Error || z2d.Path.OffsetError;

fn drawE0B5(alloc: mem.Allocator, width: f64, height: f64, offset: f64) DrawPathError!z2d.Path {
    var result: z2d.Path = .empty;
    defer if (offset != 0) {
        result.deinit(alloc);
    };

    // Coefficient for approximating a circular arc.
    const c: f64 = (math.sqrt2 - 1.0) * 4.0 / 3.0;
    const radius: f64 = @min(width, height / 2);
    try result.moveTo(alloc, 0, 0);
    try result.curveTo(
        alloc,
        radius * c,
        0,
        radius,
        radius - radius * c,
        radius,
        radius,
    );
    try result.lineTo(alloc, radius, height - radius);
    try result.curveTo(
        alloc,
        radius,
        height - radius + radius * c,
        radius * c,
        height,
        0,
        height,
    );

    return if (offset != 0) try result.offset(alloc, offset) else result;
}

fn draw25F8(alloc: mem.Allocator, width: f64, height: f64, offset: f64) DrawPathError!z2d.Path {
    return try cornerTriangleOutline(.tl, alloc, width, height, offset);
}

fn draw25F9(alloc: mem.Allocator, width: f64, height: f64, offset: f64) DrawPathError!z2d.Path {
    return try cornerTriangleOutline(.tr, alloc, width, height, offset);
}

fn draw25FA(alloc: mem.Allocator, width: f64, height: f64, offset: f64) DrawPathError!z2d.Path {
    return try cornerTriangleOutline(.bl, alloc, width, height, offset);
}

pub fn draw25FF(alloc: mem.Allocator, width: f64, height: f64, offset: f64) DrawPathError!z2d.Path {
    return try cornerTriangleOutline(.br, alloc, width, height, offset);
}

const Corner = enum { tl, tr, bl, br };

fn cornerTriangleOutline(
    comptime corner: Corner,
    alloc: mem.Allocator,
    width: f64,
    height: f64,
    offset: f64,
) DrawPathError!z2d.Path {
    var result: z2d.Path = .empty;
    defer if (offset != 0) {
        result.deinit(alloc);
    };

    const x0, const y0, const x1, const y1, const x2, const y2 =
        switch (corner) {
            .tl => .{
                0,
                0,
                0,
                height,
                width,
                0,
            },
            .tr => .{
                0,
                0,
                width,
                height,
                width,
                0,
            },
            .bl => .{
                0,
                0,
                0,
                height,
                width,
                height,
            },
            .br => .{
                0,
                height,
                width,
                height,
                width,
                0,
            },
        };

    try result.moveTo(alloc, x0, y0); // +1, nodes.len = 1
    try result.lineTo(alloc, x1, y1); // +1, nodes.len = 2
    try result.lineTo(alloc, x2, y2); // +1, nodes.len = 3
    try result.close(alloc); // +2, nodes.len = 5

    return if (offset != 0) try result.offset(alloc, offset) else result;
}
