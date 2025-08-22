// SPDX-License-Identifier: CC-BY-SA-4.0
//   Copyright © 2024-2025 Chris Marchesi

//! Case: Renders the z2d logo.
//!
//! The z2d logo is Copyright © 2024-2025 Chris Marchesi and licensed CC-BY-SA
//! 4.0. Portions of the z2d logo are derived from the [Zig
//! logo](https://github.com/ziglang/logo) and logomark, which are also
//! licensed CC-BY-SA 4.0. To view a copy of the license, visit
//! https://creativecommons.org/licenses/by-sa/4.0/.
//!
//! ## Rendering the example
//!
//! Note that this example is part of the acceptance test suite and is tailored
//! as such. To render this as a standalone example though, not much needs to
//! be done extra. To do so, add the main function (and supporting variables)
//! as given below:
//!
//!     const heap = @import("std").heap;
//!     var debug_allocator: heap.DebugAllocator(.{}) = .init;
//!
//!     pub fn main() !void {
//!         const alloc, const is_debug = switch (builtin.mode) {
//!             .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
//!             .ReleaseFast, .ReleaseSmall => .{ heap.smp_allocator, false },
//!         };
//!
//!         defer if (is_debug) {
//!             _ = debug_allocator.deinit();
//!         };
//!
//!         var sfc = try render(alloc, .default);
//!         defer sfc.deinit(alloc);
//!         try z2d.png_exporter.writeToPNGFile(sfc, "z2d-logo.png", .{});
//!     }
//!
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "080_fill_z2d_logo";

const title_font = @embedFile("./test-fonts/Montserrat-ExtraBold.ttf");
const subtitle_font = @embedFile("./test-fonts/Montserrat-Bold.ttf");

pub fn render(alloc: mem.Allocator, aa_mode: z2d.options.AntiAliasMode) !z2d.Surface {
    const width = 601;
    const height = 172;
    var sfc = try z2d.Surface.init(.image_surface_rgba, alloc, width, height);

    var context = z2d.Context.init(alloc, &sfc);
    defer context.deinit();
    context.setSourceToPixel(.{ .rgb = .{ .r = 0xF7, .g = 0xA4, .b = 0x1D } });
    context.setAntiAliasingMode(aa_mode);

    context.translate(129, 0);
    try fillLeftBrack(&context);
    context.translate(37, 0);
    try fillZAnd2d(&context);
    context.translate(253, 0);
    try fillRightBrack(&context);
    context.setIdentity();
    context.translate(0, 135);
    try fillSubtitle(&context);

    return sfc;
}

fn fillLeftBrack(context: *z2d.Context) !void {
    try context.moveTo(0, 22);
    try context.lineTo(0, 117);
    try context.lineTo(12, 117);
    try context.lineTo(31, 95);
    try context.lineTo(22, 95);
    try context.lineTo(22, 44);
    try context.lineTo(28, 44);
    try context.lineTo(46, 22);
    try context.closePath();
    try context.fill();
}

fn fillZAnd2d(context: *z2d.Context) !void {
    try context.moveTo(113, 0);
    try context.lineTo(64, 22);
    try context.lineTo(19, 22);
    try context.lineTo(0, 44);
    try context.lineTo(45.728516, 44);
    try context.lineTo(-34, 140);
    try context.lineTo(15, 117);
    try context.lineTo(60, 117);
    try context.lineTo(79, 95);
    try context.lineTo(33.427734, 95);
    try context.closePath();
    try context.fill();
    const saved_font_size = context.getFontSize();
    defer context.setFontSize(saved_font_size);
    context.setFontSize(128);
    try context.setFontToBuffer(title_font);
    defer context.deinitFont();
    try context.showText("2d", 86, -11);
}

fn fillRightBrack(context: *z2d.Context) !void {
    try context.moveTo(0, 22);
    try context.lineTo(0, 45);
    try context.lineTo(25, 45);
    try context.lineTo(25, 95);
    try context.lineTo(0, 95);
    try context.lineTo(0, 117);
    try context.lineTo(47, 117);
    try context.lineTo(47, 22);
    try context.closePath();
    try context.fill();
}

fn fillSubtitle(context: *z2d.Context) !void {
    const saved_font_size = context.getFontSize();
    defer context.setFontSize(saved_font_size);
    context.setFontSize(36);
    try context.setFontToBuffer(subtitle_font);
    defer context.deinitFont();
    try context.showText("A PURE ZIG GRAPHICS LIBRARY", 0, 0);
}
