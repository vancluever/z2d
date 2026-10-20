// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024-2026 Chris Marchesi

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

const fontpkg = @import("font.zig");
const painter = @import("painter.zig");

const Path = @import("Path.zig");
const Pattern = @import("pattern.zig").Pattern;
const Surface = @import("surface.zig").Surface;
const Transformation = @import("Transformation.zig");
const Font = fontpkg.Font;
const Glyph = @import("internal/Glyph.zig");
const GlyphOrientation = @import("options.zig").GlyphOrientation;

pub const ShowTextOptions = struct {
    /// The transformation matrix to use when drawing text. This is used as the
    /// initial matrix when tracing font outlines.
    transformation: Transformation = Transformation.identity,

    /// The size of the text in pixels. To translate from points, use
    /// `target_dpi / 72 * point_size`. The default is 16px, or 12pt @ 96 DPI.
    size: f64 = 16.0,

    /// Defines where the vertical origin is placed when rendering text.
    glyph_orientation: GlyphOrientation = .top,

    /// Options passed down to the underlying `fill` operation.
    fill_opts: painter.FillOptions = .default,

    /// Can be used to denote the default option set.
    pub const default: ShowTextOptions = .{};
};

pub const ShowTextError = ShapeTextError || painter.FillError;

/// Shows the text supplied in the UTF-8 string at the co-ordinates specified
/// by `(x, y)`.
pub fn show(
    alloc: std.mem.Allocator,
    surface: *Surface,
    pattern: *const Pattern,
    font: *Font,
    utf8: []const u8,
    x: f64,
    y: f64,
    opts: ShowTextOptions,
) ShowTextError!void {
    var shaped = try shape(alloc, font, utf8, x, y, .{
        .mode = .path_only,
        .transformation = opts.transformation,
        .size = opts.size,
        .glyph_orientation = opts.glyph_orientation,
    });
    defer shaped.deinit(alloc);
    try painter.fill(alloc, surface, pattern, shaped.path().nodes.items, opts.fill_opts);
}

/// The type of data to extract when using `shape`.
pub const ShapeMode = enum {
    /// Returns the path only, skips a few extra calculations at the end of the
    /// function.
    path_only,

    /// Returns extents only.
    extents_only,

    /// Returns both path and extents.
    all,
};

/// Extents for the drawn text, computed off of the glyphs as drawn when using
/// `shape`, and expressed in pixels. Can be used to properly position text.
///
/// Relative vertical values are oriented with a top-left origin system, versus
/// the bottom-left origin that fonts are normally expressed in. This means
/// that values such as `y_bearing` will always likely be negative, unless the
/// text lies entirely below the baseline.
///
/// Additionally, extents are always supplied in user-space co-ordinates, due
/// to the one-dimensional nature of most attributes. This means that any
/// scaling or other transformations need to be applied to the result manually.
pub const Extents = struct {
    // The x-offset where the text starts.
    x_bearing: f64,

    // The vertical distance *from the baseline* to the topmost part of
    // where the text starts. This will be negative in most cases unless
    // the text lies completely below the baseline.
    y_bearing: f64,

    // The width of the text as drawn.
    width: f64,

    // The height of the text as drawn.
    height: f64,

    // The final cumulative advance of the text as drawn.
    advance: f64,
};

pub const ShapeTextOptions = struct {
    /// Defines the data to return.
    mode: ShapeMode = .all,

    /// The transformation matrix to use when drawing text. This is used as the
    /// initial matrix when tracing font outlines and calculating extents.
    transformation: Transformation = Transformation.identity,

    /// The size of the text in pixels. To translate from points, use
    /// `target_dpi / 72 * point_size`. The default is 16px, or 12pt @ 96 DPI.
    size: f64 = 16.0,

    /// Defines where the vertical origin is placed when tracing paths.
    glyph_orientation: GlyphOrientation = .top,

    /// Can be used to denote the default option set.
    pub const default: ShapeTextOptions = .{};
};

pub const ShapeTextError = error{
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
} || std.mem.Allocator.Error || fontpkg.ReaderError || Glyph.Outline.InitError;

/// Represents the result of `shape`.
pub const ShapeTextResult = union(ShapeMode) {
    path_only: Path,
    extents_only: Extents,
    all: struct {
        path: Path,
        extents: Extents,
    },

    /// Releases the result's `Path`, if it exists.
    pub fn deinit(self: *ShapeTextResult, alloc: std.mem.Allocator) void {
        switch (self.*) {
            .path_only => |*p| p.deinit(alloc),
            .extents_only => {},
            .all => |*s| s.path.deinit(alloc),
        }

        self.* = undefined;
    }

    /// Asserts a result type of `.path_only` or `.all`.
    pub fn path(self: *ShapeTextResult) *Path {
        return switch (self.*) {
            .path_only => |*p| p,
            .extents_only => unreachable,
            .all => |*shaped| &shaped.path,
        };
    }

    /// Asserts a result type of `.extents_only` or `.all`.
    pub fn extents(self: *const ShapeTextResult) Extents {
        return switch (self.*) {
            .path_only => unreachable,
            .extents_only => |e| e,
            .all => |s| s.extents,
        };
    }
};

/// Shapes the supplied UTF-8 string and returns the resulting path and/or
/// extents, depending on the value supplied to `opts.mode`. The details can be
/// used to determine where to place text and/or defer drawing to a later time.
///
/// Note that the co-ordinates supplied this function are only useful when
/// generating a path with `opts.mode` set to `.all`.
pub fn shape(
    alloc: std.mem.Allocator,
    font: *Font,
    utf8: []const u8,
    x: f64,
    y: f64,
    opts: ShapeTextOptions,
) ShapeTextError!ShapeTextResult {
    var glyphs: std.AutoHashMapUnmanaged(u21, Glyph) = .empty;
    defer glyphs.deinit(alloc);

    var outlines: std.AutoHashMapUnmanaged(u21, Glyph.Outline) = .empty;
    defer {
        var iter = outlines.valueIterator();
        while (iter.next()) |outline| outline.deinit(alloc);
        outlines.deinit(alloc);
    }

    // Initialize a path for modes that we need it in
    var path_: ?Path = if (opts.mode != .extents_only) path: {
        var path: Path = .empty;
        path.transformation = opts.transformation;
        break :path path;
    } else null;

    errdefer {
        if (path_) |*path| path.deinit(alloc);
    }

    // Set up an ArrayList for our codepoints
    var codepoints: std.ArrayListUnmanaged(u21) = .empty;
    defer codepoints.deinit(alloc);

    // Go over our UTF-8 string now and break it up into their individual
    // codepoints.
    {
        var i: usize = 0;
        while (i < utf8.len) {
            const codepoint_len = try std.unicode.utf8ByteSequenceLength(utf8[i]);
            if (i + codepoint_len > utf8.len) {
                return error.InvalidSequence;
            }
            const codepoint: u21 = switch (codepoint_len) {
                1 => @intCast(utf8[i]),
                2 => try std.unicode.utf8Decode2(utf8[i..][0..2].*),
                3 => try std.unicode.utf8Decode3(utf8[i..][0..3].*),
                4 => try std.unicode.utf8Decode4(utf8[i..][0..4].*),
                else => unreachable,
            };
            try codepoints.append(alloc, codepoint);
            i += codepoint_len;
        }
    }

    // Now that we have our codepoints, we can actually start our extent
    // calculations and optional path drawing. We cache glyphs and outlines
    // along the way.
    //
    // Get our scale
    const scale = opts.size / @as(f64, @floatFromInt(font.meta.units_per_em));

    // Store an advance. We add on to this after drawing each glyph.
    var advance: f64 = 0.0;

    // Store our raw glyph metrics.
    var box_x_min_: ?f64 = null;
    var box_x_max: f64 = undefined;
    var box_y_min: i16 = 0;
    var box_y_max: i16 = 0;

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

        if (current_glyph.outline != .none) {
            // We have an outline, so we want to get it, even if we're not
            // drawing, so that we can keep track of metrics if we need to
            // return them later.
            var outline = outlines.get(codepoint) orelse outline: {
                const o = try Glyph.Outline.init(alloc, font, current_glyph, opts.glyph_orientation);
                try outlines.put(alloc, codepoint, o);
                break :outline o;
            };

            // Record our box values to help keep track of the final bounding box.
            if (box_x_min_ == null) {
                box_x_min_ = advance + outline.x_min * scale;
            }
            if (idx == codepoints.items.len - 1) {
                // Don't need to record this until the final glyph
                box_x_max = advance + outline.x_max * scale;
            }

            // We need to keep track of vertical extrema every glyph.
            box_y_min = @min(box_y_min, outline.y_min);
            box_y_max = @max(box_y_max, outline.y_max);

            // Only draw if we need to.
            if (path_) |*path| {
                // We save and restore the ctm after drawing each codepoint
                const saved_ctm = path.transformation;
                defer path.transformation = saved_ctm;

                // Phantom point 1 is equal to xMin - lsb, but only if the
                // lsb_is_at_x_zero flag is false. If it is, we don't need to
                // adjust, and can just rely on the xMin in the glyph.
                const pp1: f64 = if (!font.meta.lsb_is_at_x_zero)
                    @as(f64, @floatFromInt(outline.x_min - current_glyph.lsb)) * scale
                else
                    0.0;

                // Set up our translate for the single glyph, then scale
                path.transformation = path.transformation.translate(
                    x + advance + pp1,
                    y,
                ).scale(scale, scale);

                // Append the glyph to the path now
                try path.appendPath(alloc, &outline.path);
            }
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

    // For modes that returns a path, asserts a non-null path (should always be set).
    return switch (opts.mode) {
        .path_only => .{ .path_only = path_.? },
        .extents_only, .all => with_extents: {
            const extents: Extents = if (box_x_min_) |box_x_min| .{
                .x_bearing = box_x_min,
                .y_bearing = box_y_max * -scale,
                .width = (box_x_max - box_x_min),
                .height = (box_y_max - box_y_min) * scale,
                .advance = advance,
            } else .{
                // When we had no effectively drawn text, the only thing we
                // record is the advance, to allow for advancing on pure
                // whitespace.
                .x_bearing = 0.0,
                .y_bearing = 0.0,
                .width = 0.0,
                .height = 0.0,
                .advance = advance,
            };

            break :with_extents switch (opts.mode) {
                .extents_only => .{ .extents_only = extents },
                .all => .{ .all = .{
                    .path = path_.?,
                    .extents = extents,
                } },
                else => unreachable,
            };
        },
    };
}

test "text.shape will corretly return extents in .extents_only" {
    const alloc = std.testing.allocator;
    var font: Font = try Font.loadBufferOffset(@embedFile("./internal/test-fonts/Inter-Regular.subset.ttf"), 0);
    const shaped = try shape(alloc, &font, "a", 0, 0, .{ .mode = .extents_only });
    const extents = shaped.extents();
    try std.testing.expect(extents.x_bearing != 0.0);
    try std.testing.expect(extents.y_bearing != 0.0);
    try std.testing.expect(extents.width != 0.0);
    try std.testing.expect(extents.height != 0.0);
    try std.testing.expect(extents.advance != 0.0);
}
