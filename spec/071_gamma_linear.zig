// SPDX-License-Identifier: 0BSD
//   Copyright © 2024 Chris Marchesi

//! Case: Gamma testing (linear version).
//!
//! This test draws two gray sections with four red -> green -> blue gradients
//! inside. The top square is composed in linear space, the bottom
//! square is composed in sRGB. Our gradients are drawn with different color
//! and interpolation space respectively, as (.linear, .linear_rgb), (.srgb,
//! .linear_rgb), (.linear, .srgb), and (.srgb, .srgb).
//!
//! The PNG is exported in linear space.
//!
//! The ultimate effect should be that the bottom section should look darker
//! than the top section, due to the gamma transfer function. The effects are
//! similar on the gradients, with the even gradients looking darker than the
//! odd ones. A noticeable lack of secondary colors are present in the sRGB
//! interpolations.
//!
//! Note that YMMV may examining this and 072_gamma_srgb.zig for differences or
//! for the notes above, depending on how hard your image viewer works to
//! properly adjust the color.
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "071_gamma_linear";
pub const color_profile: z2d.color.RGBProfile = .linear;

const width = 400;
const height = 300;

pub fn render(alloc: mem.Allocator) !z2d.Surface {
    var sfc = try z2d.Surface.init(.image_surface_rgb, alloc, width, height);
    var context = try z2d.Context.init(alloc, &sfc);
    defer context.deinit();
    context.setAntiAliasingMode(.none);

    try drawGray(&context, 0, .linear);
    try drawGray(&context, 1, .srgb);

    try drawGradient(&context, 0, .linear, .linear_rgb);
    try drawGradient(&context, 1, .srgb, .linear_rgb);
    try drawGradient(&context, 2, .linear, .srgb);
    try drawGradient(&context, 3, .srgb, .srgb);

    return sfc;
}

fn drawGray(context: *z2d.Context, pos: f64, profile: z2d.color.RGBProfile) !void {
    const px = z2d.Pixel.fromColor(switch (profile) {
        .linear => .{ .rgb = .{ 0.3, 0.3, 0.3 } },
        .srgb => .{ .srgb = .{ 0.3, 0.3, 0.3 } },
    });
    context.setSourceToPixel(px);
    context.translate(0, pos * height / 2);
    try context.moveTo(0, 0);
    try context.lineTo(width, 0);
    try context.lineTo(width, height / 2);
    try context.lineTo(0, height / 2);
    try context.closePath();
    context.setIdentity();
    try context.fill();
    context.resetPath();
}

fn drawGradient(
    context: *z2d.Context,
    pos: f64,
    stop_profile: z2d.color.RGBProfile,
    interpolation_method: z2d.color.InterpolationMethod,
) !void {
    const s0: z2d.Color.InitArgs = switch (stop_profile) {
        .linear => .{ .rgb = .{ 0.80, 0, 0 } },
        .srgb => .{ .srgb = .{ 0.80, 0, 0 } },
    };
    const s1: z2d.Color.InitArgs = switch (stop_profile) {
        .linear => .{ .rgb = .{ 0, 0.80, 0 } },
        .srgb => .{ .srgb = .{ 0, 0.80, 0 } },
    };
    const s2: z2d.Color.InitArgs = switch (stop_profile) {
        .linear => .{ .rgb = .{ 0, 0, 0.80 } },
        .srgb => .{ .srgb = .{ 0, 0, 0.80 } },
    };
    const offset: f64 = 30;
    const gradient_width: f64 = width - offset * 2;
    const gradient_height: f64 = (height - offset * 2) / 4;
    var stops: [3]z2d.gradient.Stop = undefined;
    var gradient = z2d.Gradient.init(.{
        .type = .{ .linear = .{
            .x0 = 0,
            .y0 = gradient_height / 2,
            .x1 = gradient_width,
            .y1 = gradient_height / 2,
        } },
        .stops = &stops,
        .method = interpolation_method,
    });
    gradient.addStopAssumeCapacity(0, s0);
    gradient.addStopAssumeCapacity(0.5, s1);
    gradient.addStopAssumeCapacity(1, s2);
    context.translate(offset, offset + gradient_height * pos);
    context.setSource(gradient.asPattern());
    try context.moveTo(0, 0);
    try context.lineTo(gradient_width, 0);
    try context.lineTo(gradient_width, gradient_height);
    try context.lineTo(0, gradient_height);
    try context.closePath();
    context.setIdentity();
    try context.fill();
    context.resetPath();
    context.setSourceToPixel(.{ .rgb = .{ .r = 0, .g = 0, .b = 0 } });
}
