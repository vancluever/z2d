// SPDX-License-Identifier: 0BSD
//   Copyright © 2024-2026 Chris Marchesi

//! Case: Demonstrates the use of text shaping and the use/calculation of
//! various metrics to be able to correctly position text.
//!
//! We draw text three times, each one positioned at our various origin points:
//! the top of the text (the default, but we do it explicitly), the baseline,
//! and the bottom. We then draw lines around all sections we have metrics for.
//!
//! Note that in order to generate meaningful visualizations, we need to just
//! use lowercase letters that do not go past the average x-height and do not
//! descend, this is so that we can properly demarcate the various metrics
//! (bounding box, vertical metrics, etc).
const Io = @import("std").Io;
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "088_text_dimensions";

const margin = 3;
const dash_width = margin;
const canvas_width = 200;
const canvas_height = 200;
const sfc_width = canvas_width;
const sfc_height = canvas_height * 3;
const font_size = 64;
const draw_text_x = 20;
const draw_text_y = canvas_height / 2;
const text_pattern: z2d.Pattern = .{ .opaque_pattern = .{ .pixel = .fromColor(.{ .rgb = .{ 1, 1, 1 } }) } };
const advance_pattern: z2d.Pattern = .{ .opaque_pattern = .{ .pixel = .fromColor(.{ .rgb = .{ 1, 1, 0 } }) } };
const box_pattern: z2d.Pattern = .{ .opaque_pattern = .{ .pixel = .fromColor(.{ .rgb = .{ 1, 0, 0 } }) } };
const ascender_pattern: z2d.Pattern = .{ .opaque_pattern = .{ .pixel = .fromColor(.{ .rgb = .{ 0, 1, 0 } }) } };
const baseline_pattern: z2d.Pattern = .{ .opaque_pattern = .{ .pixel = .fromColor(.{ .rgb = .{ 0, 1, 1 } }) } };
const descender_pattern: z2d.Pattern = .{ .opaque_pattern = .{ .pixel = .fromColor(.{ .rgb = .{ 0, 0, 1 } }) } };
const spacing_pattern: z2d.Pattern = .{ .opaque_pattern = .{ .pixel = .fromColor(.{ .rgb = .{ 1, 0, 1 } }) } };

pub fn drawTextWithExtents(
    alloc: mem.Allocator,
    font: *z2d.font.Font,
    draw_sfc: *z2d.Surface,
    text: []const u8,
    aa_mode: z2d.options.AntiAliasMode,
    orientation: z2d.options.GlyphOrientation,
    draw_idx: comptime_int,
) !void {
    // Our canvas
    var canvas_sfc = try z2d.Surface.init(.image_surface_rgb, alloc, canvas_width, canvas_height);
    defer canvas_sfc.deinit(alloc);

    // Shape the text before drawing it
    var shaped = try z2d.text.shape(
        alloc,
        font,
        text,
        draw_text_x,
        draw_text_y,
        .{ .size = font_size, .glyph_orientation = orientation },
    );
    defer shaped.deinit(alloc);

    // Draw the text on the canvas
    try z2d.painter.fill(
        alloc,
        &canvas_sfc,
        &text_pattern,
        shaped.path().nodes.items,
        .{ .anti_aliasing_mode = aa_mode },
    );

    // We expect text to be drawn.
    const font_extents = font.extents(font_size);
    const text_extents = shaped.extents();

    // Draw our lines at our various boundaries we have.
    {
        // x-origin and advance
        const origin = draw_text_x;
        const advance = origin + text_extents.advance;
        inline for (.{ origin, advance }) |x| {
            var path: z2d.Path = .empty;
            defer path.deinit(alloc);
            try path.moveTo(alloc, x, margin);
            try path.lineTo(alloc, x, canvas_height - margin);
            try z2d.painter.stroke(
                alloc,
                &canvas_sfc,
                &advance_pattern,
                path.nodes.items,
                .{
                    .dashes = &.{dash_width},
                    .anti_aliasing_mode = aa_mode,
                    .hairline = true,
                },
            );
        }
    }
    {
        // Bounding box: x bearings
        const lsb = draw_text_x + text_extents.x_bearing;
        const rsb = lsb + text_extents.width;
        inline for (.{ lsb, rsb }) |x| {
            var path: z2d.Path = .empty;
            defer path.deinit(alloc);
            try path.moveTo(alloc, x, margin);
            try path.lineTo(alloc, x, canvas_height - margin);
            try z2d.painter.stroke(
                alloc,
                &canvas_sfc,
                &box_pattern,
                path.nodes.items,
                .{
                    .dashes = &.{dash_width},
                    .anti_aliasing_mode = aa_mode,
                    .hairline = true,
                },
            );
        }
    }
    {
        // Bounding box: y bearings
        const top = switch (orientation) {
            .top => draw_text_y - (font_extents.ascender - text_extents.y_bearing),
            .baseline => draw_text_y + text_extents.y_bearing,
            .bottom => draw_text_y - font_extents.descender + text_extents.y_bearing,
        };
        const bottom = top + text_extents.height;
        inline for (.{ top, bottom }) |y| {
            var path: z2d.Path = .empty;
            defer path.deinit(alloc);
            try path.moveTo(alloc, 0, y);
            try path.lineTo(alloc, canvas_width, y);
            try z2d.painter.stroke(
                alloc,
                &canvas_sfc,
                &box_pattern,
                path.nodes.items,
                .{
                    .dashes = &.{dash_width},
                    .anti_aliasing_mode = aa_mode,
                    .hairline = true,
                },
            );
        }
    }
    {
        // Font vertical metrics
        const ascender = switch (orientation) {
            .top => draw_text_y,
            .baseline => draw_text_y + font_extents.ascender,
            .bottom => draw_text_y + (font_extents.ascender - font_extents.descender),
        };
        const baseline = switch (orientation) {
            .top => draw_text_y - font_extents.ascender,
            .baseline => draw_text_y,
            .bottom => draw_text_y - font_extents.descender,
        };
        const descender = switch (orientation) {
            .top => draw_text_y - font_extents.ascender + font_extents.descender,
            .baseline => draw_text_y + font_extents.descender,
            .bottom => draw_text_y,
        };
        const spacing = switch (orientation) {
            .top => draw_text_y + font_extents.height,
            .baseline => draw_text_y + font_extents.height + font_extents.ascender,
            .bottom => draw_text_y + (font_extents.height + (font_extents.ascender - font_extents.descender)),
        };
        inline for (
            .{ ascender, baseline, descender, spacing },
            .{ ascender_pattern, baseline_pattern, descender_pattern, spacing_pattern },
        ) |y, pattern| {
            var path: z2d.Path = .empty;
            defer path.deinit(alloc);
            try path.moveTo(alloc, 0, y);
            try path.lineTo(alloc, canvas_width, y);
            try z2d.painter.stroke(
                alloc,
                &canvas_sfc,
                &pattern,
                path.nodes.items,
                .{
                    .dashes = &.{dash_width},
                    .anti_aliasing_mode = aa_mode,
                    .hairline = true,
                },
            );
        }
    }

    // Put result on surface.
    z2d.compositor.SurfaceCompositor.run(draw_sfc, 0, canvas_height * draw_idx, 1, .{
        .{
            .operator = .src,
            .src = .{ .surface = &canvas_sfc },
        },
    }, .{});
}

pub fn render(io: Io, alloc: mem.Allocator, aa_mode: z2d.options.AntiAliasMode) !z2d.Surface {
    _ = io;
    var sfc = try z2d.Surface.init(.image_surface_rgb, alloc, sfc_width, sfc_height);
    var font = font: {
        const font_file = z2d.font.File.loadBuffer(@embedFile("test-fonts/DejaVuSans.ttf")) catch unreachable;
        break :font font_file.loadFontIndex(0) catch unreachable;
    };
    try drawTextWithExtents(alloc, &font, &sfc, "ooze", aa_mode, .top, 0);
    try drawTextWithExtents(alloc, &font, &sfc, "ooze", aa_mode, .baseline, 1);
    try drawTextWithExtents(alloc, &font, &sfc, "ooze", aa_mode, .bottom, 2);
    return sfc;
}
