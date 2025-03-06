// SPDX-License-Identifier: MIT
//   Copyright © 2024 Chris Marchesi
//   Copyright (c) 2024 Mitchell Hashimoto

//! Case: Renders and fills the ghostty logo (https://ghostty.org) using a
//! linear 3-stop gradient. Adapted from the SVG.
//!
//! The logo is used under the terms of the MIT license (for lack of a better
//! one for creative works, will update if one is established for the logos).
//! Below is a copy of the MIT license.
//!
//! MIT License
//!
//! Copyright (c) 2024 Mitchell Hashimoto
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
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "060_ghostty_logo";

pub fn render(alloc: mem.Allocator, aa_mode: z2d.options.AntiAliasMode) !z2d.Surface {
    const width = 82;
    const height = 100;
    var sfc = try z2d.Surface.init(.image_surface_rgba, alloc, width, height);

    var context = try z2d.Context.init(alloc, &sfc);
    defer context.deinit();
    context.setAntiAliasingMode(aa_mode);

    var gradient = z2d.Gradient.init(.{ .type = .{ .linear = .{
        .x0 = 0,
        .y0 = 49,
        .x1 = 82,
        .y1 = 49,
    } } });
    defer gradient.deinit(alloc);
    try gradient.addStop(alloc, 0, .{ .rgb = .{ 1, 0, 0 } });
    try gradient.addStop(alloc, 0.5, .{ .rgb = .{ 0, 1, 0 } });
    try gradient.addStop(alloc, 1, .{ .rgb = .{ 0, 0, 1 } });
    context.setSource(gradient.asPattern());

    try context.moveTo(62.186, 97.000);
    try context.curveTo(58.431, 97.000, 54.746, 95.875, 51.637, 93.800);
    try context.curveTo(48.528, 95.875, 44.836, 97.000, 41.088, 97.000);
    try context.curveTo(37.339, 97.000, 33.647, 95.875, 30.538, 93.800);
    try context.curveTo(27.451, 95.875, 23.878, 96.972, 20.115, 97.000);
    try context.lineTo(20.003, 97.000);
    try context.curveTo(14.897, 97.000, 10.107, 94.968, 6.499, 91.282);
    try context.curveTo(2.948, 87.653, 0.993, 82.878, 0.993, 77.835);
    try context.lineTo(0.993, 41.088);
    try context.curveTo(1.000, 18.983, 18.983, 1.000, 41.088, 1.000);
    try context.curveTo(63.192, 1.000, 81.176, 18.983, 81.176, 41.088);
    try context.lineTo(81.176, 77.849);
    try context.curveTo(81.176, 88.026, 73.298, 96.423, 63.242, 96.972);
    try context.curveTo(62.890, 96.993, 62.538, 97.000, 62.186, 97.000);
    try context.closePath();
    try context.fill();

    context.setSourceToPixel(.{ .rgb = .{ .r = 0x00, .g = 0x00, .b = 0x00 } });
    context.resetPath();
    try context.moveTo(62.186, 92.780);
    try context.curveTo(58.832, 92.780, 55.554, 91.627, 52.945, 89.531);
    try context.curveTo(52.495, 89.165, 52.010, 89.095, 51.686, 89.095);
    try context.curveTo(51.173, 89.095, 50.652, 89.278, 50.223, 89.622);
    try context.curveTo(47.635, 91.662, 44.393, 92.787, 41.088, 92.787);
    try context.curveTo(37.782, 92.787, 34.540, 91.662, 31.952, 89.622);
    try context.curveTo(31.537, 89.292, 31.044, 89.123, 30.538, 89.123);
    try context.curveTo(30.032, 89.123, 29.539, 89.299, 29.125, 89.622);
    try context.curveTo(26.529, 91.669, 23.407, 92.759, 20.094, 92.787);
    try context.lineTo(19.996, 92.787);
    try context.curveTo(16.050, 92.787, 12.330, 91.212, 9.524, 88.343);
    try context.curveTo(6.753, 85.508, 5.219, 81.781, 5.219, 77.849);
    try context.lineTo(5.219, 41.102);
    try context.curveTo(5.219, 21.311, 21.311, 5.220, 41.088, 5.220);
    try context.curveTo(60.864, 5.220, 76.956, 21.311, 76.956, 41.088);
    try context.lineTo(76.956, 77.849);
    try context.curveTo(76.956, 85.782, 70.830, 92.330, 63.009, 92.759);
    try context.curveTo(62.735, 92.773, 62.461, 92.780, 62.186, 92.780);
    try context.closePath();
    try context.fill();

    context.setSource(gradient.asPattern());
    context.resetPath();
    try context.moveTo(72.736, 41.088);
    try context.lineTo(72.736, 77.849);
    try context.curveTo(72.736, 83.476, 68.396, 88.237, 62.777, 88.547);
    try context.curveTo(60.048, 88.694, 57.530, 87.808, 55.582, 86.240);
    try context.curveTo(53.247, 84.362, 49.963, 84.446, 47.607, 86.303);
    try context.curveTo(45.813, 87.717, 43.549, 88.561, 41.080, 88.561);
    try context.curveTo(38.612, 88.561, 36.354, 87.717, 34.561, 86.303);
    try context.curveTo(32.177, 84.425, 28.892, 84.425, 26.508, 86.303);
    try context.curveTo(24.729, 87.703, 22.492, 88.547, 20.059, 88.561);
    try context.curveTo(14.214, 88.603, 9.439, 83.680, 9.439, 77.835);
    try context.lineTo(9.439, 41.088);
    try context.curveTo(9.439, 23.611, 23.610, 9.440, 41.087, 9.440);
    try context.curveTo(58.564, 9.440, 72.736, 23.611, 72.736, 41.088);
    try context.closePath();
    try context.fill();

    context.setSourceToPixel(.{ .rgb = .{ .r = 0x00, .g = 0x00, .b = 0x00 } });
    context.resetPath();
    try context.moveTo(34.842, 38.310);
    try context.lineTo(23.048, 31.502);
    try context.curveTo(21.515, 30.616, 19.546, 31.143, 18.660, 32.676);
    try context.curveTo(17.773, 34.210, 18.301, 36.179, 19.834, 37.065);
    try context.lineTo(26.811, 41.095);
    try context.lineTo(19.834, 45.125);
    try context.curveTo(18.301, 46.011, 17.773, 47.973, 18.660, 49.513);
    try context.curveTo(19.546, 51.047, 21.508, 51.574, 23.048, 50.688);
    try context.lineTo(34.842, 43.880);
    try context.curveTo(36.981, 42.642, 36.981, 39.555, 34.842, 38.317);
    try context.lineTo(34.842, 38.310);
    try context.closePath();
    try context.fill();

    context.resetPath();
    try context.moveTo(61.547, 37.874);
    try context.lineTo(46.053, 37.874);
    try context.curveTo(44.281, 37.874, 42.839, 39.309, 42.839, 41.088);
    try context.curveTo(42.839, 42.867, 44.274, 44.302, 46.053, 44.302);
    try context.lineTo(61.547, 44.302);
    try context.curveTo(63.319, 44.302, 64.761, 42.867, 64.761, 41.088);
    try context.curveTo(64.761, 39.309, 63.326, 37.874, 61.547, 37.874);
    try context.closePath();
    try context.fill();
    return sfc;
}
