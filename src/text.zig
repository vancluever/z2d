// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024-2025 Chris Marchesi

//! Contains unmanaged functions for text rasterization.
//!
//! Note that text display is an exhaustive topic and this package at this
//! point in time certainly does not cover all areas. Namely, anything outside
//! of Latin text or anything that requires non-left-to-right rendering will
//! likely not render correctly; these features are WIP. Kerning/GPOS is
//! supported so contextual spacing should be applied correctly in the
//! aforementioned Latin left-to-right fashion, in addition to diacritical
//! marks and composite glyphs.
//!
//! Rendering text requires a font to be loaded externally. See `Font` for more
//! details on loading fonts and passing them in.

const std = @import("std");
const debug = @import("std").debug;
const math = @import("std").math;
const mem = @import("std").mem;
const unicode = @import("std").unicode;

const painter = @import("painter.zig");

const Path = @import("Path.zig");
const Pattern = @import("pattern.zig").Pattern;
const Surface = @import("surface.zig").Surface;
const Transformation = @import("Transformation.zig");
const Font = @import("Font.zig");
const Glyph = @import("internal/Glyph.zig");

pub const ShowTextOpts = struct {
    /// The transformation matrix to use when drawing text. This is used as the
    /// initial matrix when tracing font outlines.
    transformation: Transformation = Transformation.identity,

    /// The size of the text in pixels. To translate from points, use
    /// `target_dpi / 72 * point_size`. The default is 16px, or 12pt @ 96 DPI.
    size: f64 = 16.0,

    /// Options passed down to the underlying `fill` operation.
    fill_opts: painter.FillOpts,
};

pub const ShowTextError = error{
    /// The supplied text has an invalid UTF-8 start byte.
    Utf8InvalidStartByte,

    /// A byte in the UTF-8 sequence was expected to be a continuation byte,
    /// but was not.
    Utf8ExpectedContinuation,

    /// The codepoint described in the UTF-8 sequence uses more bytes than it
    /// should be as encoded, and is not allowed.
    Utf8OverlongEncoding,

    /// The UTF-8 sequence encodes a surrogate half and is (currently) not allowed.
    Utf8EncodesSurrogateHalf,

    /// The UTF-8 sequence describes a codepoint too large for UTF-8 (>
    /// U+10FFFF).
    Utf8CodepointTooLarge,

    /// The supplied text has an invalid UTF-8 sequence.
    InvalidSequence,
} || mem.Allocator.Error || Font.FileError || Glyph.Outline.InitError || painter.FillError;

/// Shows the text supplied in the UTF-8 string at the co-ordinates specified
/// by `(x, y)`.
pub fn show(
    alloc: mem.Allocator,
    surface: *Surface,
    pattern: *const Pattern,
    font: *Font,
    utf8: []const u8,
    x: f64,
    y: f64,
    opts: ShowTextOpts,
) ShowTextError!void {
    var glyphs: std.AutoHashMapUnmanaged(u21, Glyph) = .empty;
    defer glyphs.deinit(alloc);

    var outlines: std.AutoHashMapUnmanaged(u21, Glyph.Outline) = .empty;
    defer {
        var iter = outlines.valueIterator();
        while (iter.next()) |outline| outline.deinit(alloc);
        outlines.deinit(alloc);
    }

    // Initialize a path
    var path: Path = .empty;
    path.transformation = opts.transformation;
    defer path.deinit(alloc);

    // Set up an ArrayList for our codepoints
    var codepoints: std.ArrayListUnmanaged(u21) = .empty;
    defer codepoints.deinit(alloc);

    // Go over our UTF-8 string now and break it up into their individual
    // codepoints.
    {
        var i: usize = 0;
        while (i < utf8.len) {
            const codepoint_len = try unicode.utf8ByteSequenceLength(utf8[i]);
            if (i + codepoint_len > utf8.len) {
                return ShowTextError.InvalidSequence;
            }
            const codepoint: u21 = switch (codepoint_len) {
                1 => @intCast(utf8[i]),
                2 => try unicode.utf8Decode2(utf8[i..][0..2].*),
                3 => try unicode.utf8Decode3(utf8[i..][0..3].*),
                4 => try unicode.utf8Decode4(utf8[i..][0..4].*),
                else => unreachable,
            };
            try codepoints.append(alloc, codepoint);
            i += codepoint_len;
        }
    }

    // Now that we have our codepoints, we can actually start drawing. We cache
    // glyphs and outlines along the way.
    {
        // Get our scale
        const scale = opts.size / @as(f64, @floatFromInt(font.meta.units_per_em));

        // Store an advance. We add on to this after drawing each glyph.
        var advance: f64 = 0.0;

        for (codepoints.items, 0..) |codepoint, idx| {
            const current_glyph = glyphs.get(codepoint) orelse glyph: {
                const g = try Glyph.init(font, codepoint);
                try glyphs.put(alloc, codepoint, g);
                break :glyph g;
            };

            // Check the next glyph too for things such as kerning and what
            // not, cached for the next lookup as well.
            const next_glyph_: ?Glyph = if (idx + 1 < codepoints.items.len) next_: {
                const next_codepoint = codepoints.items[idx + 1];
                break :next_ glyphs.get(next_codepoint) orelse glyph: {
                    const g = try Glyph.init(font, next_codepoint);
                    try glyphs.put(alloc, next_codepoint, g);
                    break :glyph g;
                };
            } else null;

            // Only need to draw the glyph if we actually have an outline for
            // this codepoint (i.e., not whitespace).
            if (current_glyph.outline != .none) {
                // We save and restore the ctm after drawing each codepoint
                const saved_ctm = path.transformation;
                defer path.transformation = saved_ctm;

                var outline = outlines.get(codepoint) orelse outline: {
                    const o = try Glyph.Outline.init(alloc, font, current_glyph);
                    try outlines.put(alloc, codepoint, o);
                    break :outline o;
                };

                // Phantom point 1 is equal to xMin - lsb, but only if the
                // lsb_is_at_x_zero flag is false. If it is, we don't need to
                // adjust, and can just rely on the xMin in the glyph.
                const pp1: f64 = if (!font.meta.lsb_is_at_x_zero)
                    @floatFromInt(outline.x_min - current_glyph.lsb)
                else
                    0.0;

                // Set up our translate for the single glyph, then scale
                path.transformation = path.transformation.translate(
                    x + advance + pp1,
                    y,
                ).scale(scale, scale);

                // Append the glyph to the path now
                try outline.appendToPath(alloc, &path);
            }

            // Finally, update the advance, offset by any kerning (if it exists).
            const kern: f64 = if (next_glyph_) |next_glyph|
                @floatFromInt(try Glyph.getKernAdvance(font, current_glyph.index, next_glyph.index))
            else
                0.0;
            advance += (@as(f64, @floatFromInt(if (current_glyph.advance > 0)
                current_glyph.advance
            else
                font.meta.advance_width_max)) + kern) * scale;
        }
    }

    // Path building is finally finished and we can render, so pass down to the
    // painter now.
    try painter.fill(alloc, surface, pattern, path.nodes.items, opts.fill_opts);
}
