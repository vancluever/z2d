// SPDX-License-Identifier: 0BSD
//   Copyright © 2024-2025 Chris Marchesi

//! Case: Renders hairline strokes of various shapes.
const math = @import("std").math;
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "081_stroke_hairline";

const sub_sfc_width = 300;
const sub_sfc_height = 300;

pub fn render(alloc: mem.Allocator, aa_mode: z2d.options.AntiAliasMode) !z2d.Surface {
    const width = 600;
    const height = 2100;
    var sfc = try z2d.Surface.init(.image_surface_rgb, alloc, width, height);

    var context = z2d.Context.init(alloc, &sfc);
    defer context.deinit();
    context.setSourceToPixel(.{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } });
    context.setAntiAliasingMode(aa_mode);
    context.setHairline(true);

    // drawn at (0, 0)
    try drawTriangle(&context);
    {
        context.translate(300, 0);
        defer context.setIdentity();
        try drawSquare(&context);
    }
    {
        context.translate(0, 300);
        defer context.setIdentity();
        try drawStar(&context);
    }
    {
        context.translate(300, 300);
        defer context.setIdentity();
        try drawBezier(&context);
    }
    {
        context.translate(0, 600);
        defer context.setIdentity();
        try drawCircle(&context);
    }
    {
        context.translate(300, 600);
        defer context.setIdentity();
        try drawEllipse(&context);
    }
    {
        context.translate(150, 900);
        defer context.setIdentity();
        try drawDots(&context);
    }

    // Same as above (save the single-path dots) but with dashes. We've
    // adjusted the offset to straddle the midpoint in the first triangle.
    context.setDashes(&.{ 20, 5 });
    context.setDashOffset(-6);
    {
        context.translate(0, 1200);
        defer context.setIdentity();
        try drawTriangle(&context);
    }
    {
        context.translate(300, 1200);
        defer context.setIdentity();
        try drawSquare(&context);
    }
    {
        context.translate(0, 1500);
        defer context.setIdentity();
        try drawStar(&context);
    }
    {
        context.translate(300, 1500);
        defer context.setIdentity();
        try drawBezier(&context);
    }
    {
        context.translate(0, 1800);
        defer context.setIdentity();
        try drawCircle(&context);
    }
    {
        context.translate(300, 1800);
        defer context.setIdentity();
        try drawEllipse(&context);
    }

    return sfc;
}

fn drawTriangle(context: *z2d.Context) !void {
    defer context.resetPath();
    const margin = 10;
    try context.moveTo(0 + margin, 0 + margin);
    try context.lineTo(sub_sfc_width - margin - 1, 0 + margin);
    try context.lineTo(sub_sfc_width / 2 - 1, sub_sfc_height - margin - 1);
    try context.closePath();
    try context.stroke();
}

fn drawSquare(context: *z2d.Context) !void {
    defer context.resetPath();
    const margin = 50;
    try context.moveTo(0 + margin, 0 + margin);
    try context.lineTo(sub_sfc_width - margin - 1, 0 + margin);
    try context.lineTo(sub_sfc_width - margin - 1, sub_sfc_height - margin - 1);
    try context.lineTo(0 + margin, sub_sfc_height - margin - 1);
    try context.closePath();
    try context.stroke();
}

fn drawStar(context: *z2d.Context) !void {
    defer context.resetPath();
    const margin = 20;
    const x_scale = 3;
    const y_scale = 5;
    try context.moveTo(sub_sfc_width / 2, 0 + margin); // 1
    try context.lineTo(sub_sfc_width - margin * x_scale - 1, sub_sfc_height - margin - 1); // 3
    try context.lineTo(0 + margin, 0 + margin * y_scale); // 5
    try context.lineTo(sub_sfc_width - margin - 1, 0 + margin * y_scale); // 2
    try context.lineTo(0 + margin * x_scale, sub_sfc_height - margin - 1); // 4
    try context.closePath();
    try context.stroke();
}

fn drawBezier(context: *z2d.Context) !void {
    defer context.resetPath();

    try context.moveTo(19, 149);
    try context.curveTo(89, 0, 209, 0, 279, 149);
    try context.stroke();

    context.resetPath();
    try context.moveTo(19, 199);
    try context.curveTo(89, 24, 209, 24, 279, 199);
    try context.stroke();

    context.resetPath();
    try context.moveTo(19, 249);
    try context.curveTo(89, 49, 209, 49, 279, 249);
    try context.stroke();
}

fn drawCircle(context: *z2d.Context) !void {
    try arc(context, sub_sfc_width / 6, sub_sfc_height / 6, sub_sfc_width / 3 * 2, sub_sfc_height / 3 * 2);
}

fn drawEllipse(context: *z2d.Context) !void {
    try arc(context, sub_sfc_width / 3, sub_sfc_height / 6, sub_sfc_width / 3, sub_sfc_height / 3 * 2);
}

fn drawDots(context: *z2d.Context) !void {
    defer context.resetPath();
    for (0..10) |i| {
        defer context.resetPath();
        for (0..50) |j| {
            try context.moveTo(
                @floatFromInt(sub_sfc_width / 6 + j * 4),
                @floatFromInt(sub_sfc_width / 3 + i * 10),
            );
            try context.closePath();
        }
        try context.stroke();
    }
}

fn arc(context: *z2d.Context, x: f64, y: f64, rx: f64, ry: f64) !void {
    const saved_ctm = context.getTransformation();
    defer context.setTransformation(saved_ctm);
    defer context.resetPath();
    context.translate(x + rx / 2, y + ry / 2);
    context.scale(rx / 2, ry / 2);
    try context.arc(0, 0, 1, 0, 2 * math.pi);
    try context.closePath();
    try context.stroke();
}
