// SPDX-License-Identifier: 0BSD
//   Copyright © 2025 Chris Marchesi

//! Draws a conic gradient as a pie chart.
//!
//! Note the small offset between some of the hard stops. This is because
//! gradients are not anti-aliased (as they are part of the pixel source, not a
//! drawing mask). This is a known issue in several graphics libraries, namely
//! Skia (still seems to be an open issue as of this writing, see
//! https://issues.skia.org/issues/40035287). The workaround is to offset the
//! hard stop on one side slightly enough to produce an anti-aliasing effect
//! through interpolation versus any sort of supersampling/etc). Note that if
//! you do this on conic gradients, you need to be careful to not use too much
//! offset to ensure that it still looks like a hard stop around the edges of
//! your circle.
const math = @import("std").math;
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "066_conic_pie_gradient";

pub fn render(alloc: mem.Allocator, aa_mode: z2d.options.AntiAliasMode) !z2d.Surface {
    const width = 300;
    const height = 300;
    var sfc = try z2d.Surface.init(.image_surface_rgb, alloc, width, height);
    var stop_buffer: [6]z2d.gradient.Stop = undefined;
    var gradient = z2d.gradient.Conic.initBuffer(
        149,
        149,
        0,
        &stop_buffer,
        .linear_rgb,
    );
    gradient.stops.addAssumeCapacity(0, .{ .rgb = .{ 1, 0, 0 } });
    gradient.stops.addAssumeCapacity(1.0 / 3.0, .{ .rgb = .{ 1, 0, 0 } });
    gradient.stops.addAssumeCapacity(1.0 / 3.0 + 0.005, .{ .rgb = .{ 0, 1, 0 } });
    gradient.stops.addAssumeCapacity(2.0 / 3.0, .{ .rgb = .{ 0, 1, 0 } });
    gradient.stops.addAssumeCapacity(2.0 / 3.0 + 0.005, .{ .rgb = .{ 0, 0, 1 } });
    gradient.stops.addAssumeCapacity(1, .{ .rgb = .{ 0, 0, 1 } });
    var context = try z2d.Context.init(alloc, &sfc);
    defer context.deinit();
    context.setAntiAliasingMode(aa_mode);
    context.setSource(gradient.asPatternInterface());
    try context.arc(149, 149, 100, 0, math.pi * 2);
    try context.closePath();
    try context.fill();

    return sfc;
}
