// SPDX-License-Identifier: 0BSD
//   Copyright © 2024 Chris Marchesi

//! Case: Renders miscellaneous dashed lines, covering some simple and edge
//! cases.
const mem = @import("std").mem;
const math = @import("std").math;

const z2d = @import("z2d");

pub const filename = "058_stroke_misc_dashes";

pub fn render(alloc: mem.Allocator, aa_mode: z2d.options.AntiAliasMode) !z2d.Surface {
    const width = 600;
    const height = 1700;
    var sfc = try z2d.Surface.init(.image_surface_rgb, alloc, width, height);

    var context = try z2d.Context.init(alloc, &sfc);
    defer context.deinit();
    context.setSource(.{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } });
    context.setAntiAliasingMode(aa_mode);
    context.setLineWidth(3);
    context.setDashes(&.{ 25, 5 });

    // Triangle
    context.translate(50, 50);
    try context.moveTo(100, 0);
    try context.lineTo(200, 200);
    try context.lineTo(0, 200);
    try context.closePath();
    try context.stroke();
    context.resetPath();

    // Rectangle
    context.setIdentity();
    context.translate(350, 50);
    try context.moveTo(0, 0);
    try context.lineTo(0, 200);
    try context.lineTo(200, 200);
    try context.lineTo(200, 0);
    try context.closePath();
    try context.stroke();
    context.resetPath();

    // Circle
    context.setIdentity();
    var x_offset: f64 = 50;
    var y_offset: f64 = 350;
    const diameter = 200;
    context.translate(x_offset + diameter / 2, y_offset + diameter / 2);
    context.scale(diameter / 2, diameter / 2);
    try context.arc(0, 0, 1, 0, 2 * math.pi);
    context.setIdentity();
    try context.stroke();
    context.resetPath();

    // Fill + stroke
    context.setIdentity();
    x_offset = 350;
    y_offset = 350;
    context.translate(x_offset + diameter / 2, y_offset + diameter / 2);
    context.scale(diameter / 2, diameter / 2);
    try context.arc(0, 0, 1, 0, 2 * math.pi);
    try context.closePath();
    context.setIdentity();
    context.setSource(.{ .rgb = .{ .r = 0xAA, .g = 0xAA, .b = 0xAA } });
    try context.fill();
    context.setSource(.{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } });
    try context.stroke();
    context.resetPath();

    // Ellipse (no transform on stroke)
    const ellipse_line_width: f64 = 6;
    context.setLineWidth(ellipse_line_width);
    context.setIdentity();
    x_offset = 100;
    y_offset = 650;
    const x_diameter = 100;
    const y_diameter = 200;
    context.translate(x_offset + x_diameter / 2, y_offset + y_diameter / 2);
    context.scale(x_diameter / 2, y_diameter / 2);
    try context.arc(0, 0, 1, 0, 2 * math.pi);
    context.setIdentity();
    try context.stroke();
    context.resetPath();

    // Ellipse (transform on stroke)
    //
    // This should be completely solid due to the fact that we are leaving the
    // transformation in; our user unit operation on the arc is so small
    // (xscale = 50, yscale = 100) that it never traverses the first dash.
    context.setIdentity();
    x_offset = 400;
    y_offset = 650;
    context.translate(x_offset + x_diameter / 2, y_offset + y_diameter / 2);
    context.scale(x_diameter / 2, y_diameter / 2);
    try context.arc(0, 0, 1, 0, 2 * math.pi);
    context.setLineWidth(lw: {
        var ux = ellipse_line_width;
        var uy = ellipse_line_width;
        try context.deviceToUserDistance(&ux, &uy);
        if (ux < uy) {
            break :lw uy;
        }
        break :lw ux;
    });
    try context.stroke();
    context.setIdentity();
    context.resetPath();

    // Square using the same idea as above, but we use close_path to test our
    // no-op functionality for path closures (this essentially will draw the
    // polygon as if no dash was set at all).
    context.setIdentity();
    x_offset = 50;
    y_offset = 950;
    context.translate(x_offset, y_offset);
    context.scale(200, 200);
    try context.moveTo(0, 0);
    try context.lineTo(0, 1);
    try context.lineTo(1, 1);
    try context.lineTo(1, 0);
    try context.closePath();
    context.setLineWidth(lw: {
        var ux = ellipse_line_width;
        var uy = ellipse_line_width;
        try context.deviceToUserDistance(&ux, &uy);
        if (ux < uy) {
            break :lw uy;
        }
        break :lw ux;
    });
    try context.stroke();
    context.setIdentity();
    context.resetPath();

    // Odd-dash cases
    context.setLineWidth(3);
    context.setIdentity();
    x_offset = 350;
    y_offset = 950;
    context.translate(x_offset, y_offset);
    context.setDashes(&.{28});
    try context.moveTo(0, 0);
    try context.lineTo(200, 0);
    try context.stroke();
    context.resetPath();

    context.setIdentity();
    x_offset = 350;
    y_offset = 990;
    context.translate(x_offset, y_offset);
    context.setDashes(&.{ 25, 5, 3 });
    try context.moveTo(0, 0);
    try context.lineTo(200, 0);
    try context.stroke();
    context.resetPath();

    // Capping
    context.setLineWidth(10);
    context.setLineCapMode(.round);
    context.setIdentity();
    x_offset = 350;
    y_offset = 1030;
    context.translate(x_offset, y_offset);
    context.setDashes(&.{28});
    try context.moveTo(0, 0);
    try context.lineTo(200, 0);
    try context.stroke();
    context.resetPath();

    context.setLineCapMode(.square);
    context.setIdentity();
    x_offset = 350;
    y_offset = 1070;
    context.translate(x_offset, y_offset);
    context.setDashes(&.{28});
    try context.moveTo(0, 0);
    try context.lineTo(200, 0);
    try context.stroke();
    context.resetPath();

    context.setLineCapMode(.butt);
    context.setIdentity();
    x_offset = 350;
    y_offset = 1110;
    context.translate(x_offset, y_offset);
    context.setDashes(&.{28});
    try context.moveTo(0, 0);
    try context.lineTo(200, 0);
    try context.stroke();
    context.resetPath();

    // Dots (zero-length segments)
    context.setLineCapMode(.round);
    context.setIdentity();
    x_offset = 350;
    y_offset = 1150;
    context.translate(x_offset, y_offset);
    context.setDashes(&.{ 0, 20 });
    try context.moveTo(0, 0);
    try context.lineTo(200, 0);
    try context.stroke();
    context.resetPath();

    // Squares (zero-length segments, aligned to slope)
    context.setLineCapMode(.square);
    context.setIdentity();
    x_offset = 50;
    y_offset = 1250;
    context.translate(x_offset, y_offset);
    context.setDashes(&.{ 0, 20 });
    try context.moveTo(0, 0);
    try context.lineTo(0, 200);
    try context.moveTo(20, 0);
    try context.lineTo(200, 200);
    try context.stroke();
    context.resetPath();

    // Offsets
    context.setLineCapMode(.butt);
    context.setLineWidth(3);
    context.setIdentity();
    context.setDashes(&.{25});
    context.setDashOffset(12.5);
    context.translate(350, 1225);
    try context.moveTo(0, 0);
    try context.lineTo(200, 0);
    try context.lineTo(200, 100);
    try context.lineTo(0, 100);
    try context.closePath();
    try context.stroke();
    context.resetPath();

    context.setIdentity();
    context.translate(350, 1350);
    context.setDashOffset(-12.5);
    try context.moveTo(0, 0);
    try context.lineTo(200, 0);
    try context.lineTo(200, 100);
    try context.lineTo(0, 100);
    try context.closePath();
    try context.stroke();
    context.resetPath();

    context.setLineWidth(10);
    context.setIdentity();
    context.setDashes(&.{});
    context.setDashOffset(0);
    context.translate(150, 1550);
    try context.moveTo(0, 0);
    try context.lineTo(300, 0);
    try context.stroke();
    context.resetPath();

    context.setIdentity();
    context.translate(150, 1570);
    context.setDashes(&.{ 30, 10 });
    context.setDashOffset(0);
    try context.moveTo(0, 0);
    try context.lineTo(300, 0);
    try context.stroke();
    context.resetPath();

    context.setIdentity();
    context.translate(150, 1590);
    context.setDashOffset(30);
    try context.moveTo(0, 0);
    try context.lineTo(300, 0);
    try context.stroke();
    context.resetPath();

    context.setIdentity();
    context.translate(150, 1610);
    context.setDashOffset(-30);
    try context.moveTo(0, 0);
    try context.lineTo(300, 0);
    try context.stroke();
    context.resetPath();

    context.setIdentity();
    context.translate(150, 1630);
    context.setDashOffset(10);
    try context.moveTo(0, 0);
    try context.lineTo(300, 0);
    try context.stroke();
    context.resetPath();

    context.setSource((z2d.pixel.RGBA{ .r = 255, .g = 0, .b = 0, .a = 127 }).multiply().asPixel());
    context.setIdentity();
    context.translate(150, 1590);
    context.setDashes(&.{});
    context.setDashOffset(0);
    try context.moveTo(0, 0);
    try context.relLineTo(-30, 0);
    try context.stroke();
    context.resetPath();
    context.setIdentity();
    context.translate(150, 1610);
    try context.moveTo(0, 0);
    try context.relLineTo(30, 0);
    try context.stroke();
    context.resetPath();
    context.setIdentity();
    context.translate(150, 1630);
    try context.moveTo(0, 0);
    try context.relLineTo(-10, 0);
    try context.stroke();

    return sfc;
}
