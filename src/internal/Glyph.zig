// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024-2025 Chris Marchesi
//
// Some of the code in this file (particularly the glyph search algorithms) was
// adapted from stb_truetype.h, found at https://github.com/nothings/stb.

//! Represents an instance of a glyph.
pub const Glyph = @This();

const std = @import("std");
const debug = @import("std").debug;
const io = @import("std").io;
const mem = @import("std").mem;
const testing = @import("std").testing;

const Font = @import("../Font.zig");
const Path = @import("../Path.zig");
const Transformation = @import("../Transformation.zig");

const runCases = @import("util.zig").runCases;
const TestingError = @import("util.zig").TestingError;

index: u32,
advance: u16,
lsb: i16,
outline: union(enum) {
    none: void,
    offset: u32,
},

/// Looks up the glyph for a unicode character.
pub fn init(font: *Font, codepoint: u21) Font.FileError!Glyph {
    // Glyph index
    const index = switch (font.meta.cmap_subtable_offset) {
        .bmp => |offset| try findGlyphIndexBMP(&font.file, offset, codepoint),
        .full => |offset| try findGlyphIndexFull(&font.file, offset, codepoint),
    };

    return byIndex(font, index);
}

pub fn byIndex(font: *Font, index: u32) Font.FileError!Glyph {
    // Glyph hmetrics
    var advance: u16 = undefined;
    var lsb: i16 = undefined;
    if (index < font.meta.number_of_hmetrics) {
        // Full hmetric entry
        const h_metric_offset = font.dir.hmtx + index * 4;
        try font.file.seekTo(h_metric_offset);
        advance = try font.file.reader().readInt(u16, .big);
        lsb = try font.file.reader().readInt(i16, .big);
    } else {
        // LSB only
        const h_metric_offset = font.dir.hmtx + font.meta.number_of_hmetrics * 4 + index * 2;
        try font.file.seekTo(h_metric_offset);
        advance = 0;
        lsb = try font.file.reader().readInt(i16, .big);
    }

    // glyf table offset
    const table_offset, const next_offset = offsets: {
        var result: [2]u32 = undefined;
        for (0..2) |i| {
            const loca_offset = switch (font.meta.index_to_loc_format) {
                .short => font.dir.loca + (index + i) * 2,
                .long => font.dir.loca + (index + i) * 4,
            };
            try font.file.seekTo(loca_offset);
            result[i] = font.dir.glyf + (switch (font.meta.index_to_loc_format) {
                .short => try font.file.reader().readInt(u16, .big) * 2,
                .long => try font.file.reader().readInt(u32, .big),
            });
        }

        break :offsets result;
    };

    return .{
        .index = index,
        .advance = advance,
        .lsb = lsb,
        .outline = if (table_offset == next_offset) .none else .{ .offset = table_offset },
    };
}

fn findGlyphIndexBMP(
    file: *io.FixedBufferStream([]const u8),
    cmap_subtable_offset: u32,
    codepoint: u21,
) Font.FileError!u32 {
    // Not supported for codepoints outside of the BMP. If we get this, we
    // likely do not have a full plane table, so we just return zero for the
    // index, which needs to exist and is the invalid character placeholder.
    if (codepoint > 0xffff) return 0;

    const segment_count_offset = cmap_subtable_offset + 6;
    try file.seekTo(segment_count_offset);

    const segment_count: u16 = try file.reader().readInt(u16, .big) >> 1;
    var search_range: u16 = try file.reader().readInt(u16, .big) >> 1;
    var entry_selector = try file.reader().readInt(u16, .big);
    const range_shift = try file.reader().readInt(u16, .big) >> 1;

    // do a binary search of the segments
    const end_count_offset: u32 = cmap_subtable_offset + 14;
    var search = end_count_offset;

    // they lie from endCount .. endCount + segCount
    // but searchRange is the nearest power of two, so...
    try file.seekTo(search + range_shift * 2);
    if (codepoint >= try file.reader().readInt(u16, .big)) {
        search += range_shift * 2;
    }

    // now decrement to bias correctly to find smallest
    search -= 2;

    while (entry_selector > 0) {
        search_range >>= 1;
        try file.seekTo(search + search_range * 2);
        const end = try file.reader().readInt(u16, .big);
        if (codepoint > end)
            search += search_range * 2;
        entry_selector -= 1;
    }

    search += 2;

    const item = (search - end_count_offset) >> 1;
    try file.seekTo(end_count_offset + segment_count * 2 + 2 + 2 * item);
    const start = try file.reader().readInt(u16, .big);
    try file.seekTo(end_count_offset + 2 * item);
    const last = try file.reader().readInt(u16, .big);

    if (codepoint < start or codepoint > last) {
        return 0;
    }

    try file.seekTo(end_count_offset + segment_count * 6 + 2 + 2 * item);
    const offset = try file.reader().readInt(u16, .big);
    if (offset == 0) {
        try file.seekTo(end_count_offset + segment_count * 4 + 2 + 2 * item);
        return @intCast(@as(i32, @intCast(codepoint)) + try file.reader().readInt(i16, .big));
    }

    try file.seekTo(
        offset + (codepoint - start) * 2 + end_count_offset + segment_count * 6 + 2 + 2 * item,
    );
    return try file.reader().readInt(u16, .big);
}

fn findGlyphIndexFull(
    file: *io.FixedBufferStream([]const u8),
    cmap_subtable_offset: u32,
    codepoint: u21,
) Font.FileError!u32 {
    const num_groups_offset = cmap_subtable_offset + 12;
    const map_groups_offset = cmap_subtable_offset + 16;
    try file.seekTo(num_groups_offset);
    const num_groups = try file.reader().readInt(u32, .big);
    var low: i32 = 0;
    var high: i32 = @intCast(num_groups);

    // Binary search the right group.
    while (low < high) {
        const mid = low + ((high - low) >> 1); // rounds down, so low <= mid < high
        const mid_table_offset: u32 = @intCast(@as(i32, @intCast(map_groups_offset)) + mid * 12);
        try file.seekTo(mid_table_offset);
        const start_char = try file.reader().readInt(u32, .big);
        const end_char = try file.reader().readInt(u32, .big);
        if (codepoint < start_char)
            high = mid
        else if (codepoint > end_char)
            low = mid + 1
        else
            return try file.reader().readInt(u32, .big) + codepoint - start_char;
    }

    return 0;
}

/// Get the advance value for two glyph indices in a series. This is an offset
/// that gets applied to the standard advance width.
///
/// The value is fetched first from the GPOS table, then the kern table if that
/// does not exist. If neither exist, this returns zero.
pub fn getKernAdvance(font: *Font, current: u32, next: u32) Font.FileError!i16 {
    return if (font.dir.GPOS != 0)
        getKernAdvanceGPOS(font, current, next)
    else if (font.dir.kern != 0)
        getKernAdvanceKern(font, current, next)
    else
        0;
}

fn getKernAdvanceKern(font: *Font, current: u32, next: u32) Font.FileError!i16 {
    debug.assert(font.dir.kern != 0); // Should have been checked before

    try font.file.seekTo(font.dir.kern + 2);
    const num_tables = try font.file.reader().readInt(u16, .big);
    try font.file.seekTo(font.dir.kern + 8);
    const format = try font.file.reader().readInt(u16, .big);

    if (num_tables < 1) return 0; // number of tables, need at least 1
    if (format != 1) return 0; // horizontal flag must be set in format

    var l: i32 = 0;
    var r: i32 = try font.file.reader().readInt(u16, .big) - 1;
    const needle: u32 = current << 16 | next;
    while (l <= r) {
        const m = (l + r) >> 1;
        try font.file.seekTo(font.dir.kern + 18 + (@as(u32, @intCast(m)) * 6)); // note: unaligned read
        const straw = try font.file.reader().readInt(u32, .big);
        if (needle < straw)
            r = m - 1
        else if (needle > straw)
            l = m + 1
        else
            return try font.file.reader().readInt(i16, .big);
    }

    return 0;
}

fn getKernAdvanceGPOS(font: *Font, current: u32, next: u32) Font.FileError!i16 {
    debug.assert(font.dir.GPOS != 0); // Should have been checked before

    try font.file.seekTo(font.dir.GPOS);
    const major = try font.file.reader().readInt(u16, .big);
    const minor = try font.file.reader().readInt(u16, .big);
    if (major != 1 or minor != 0) return 0;

    try font.file.seekTo(font.dir.GPOS + 8);
    const lookup_list_offset = try font.file.reader().readInt(u16, .big);
    const lookup_list = font.dir.GPOS + lookup_list_offset;
    try font.file.seekTo(lookup_list);
    const lookup_count = try font.file.reader().readInt(u16, .big);

    for (0..lookup_count) |i| {
        try font.file.seekTo(lookup_list + 2 + 2 * i);
        const lookup_offset = try font.file.reader().readInt(u16, .big);
        const lookup_table = lookup_list + lookup_offset;

        try font.file.seekTo(lookup_table);
        const lookup_type = try font.file.reader().readInt(u16, .big);
        try font.file.seekTo(lookup_table + 4);
        const subtable_count = try font.file.reader().readInt(u16, .big);
        const subtable_offsets = lookup_table + 6;

        // Skip pair adjustments and extension tables
        if (lookup_type != 2 and lookup_type != 9) continue;

        lookup_subtables: for (0..subtable_count) |sti| {
            try font.file.seekTo(subtable_offsets + 2 * sti);
            const subtable_offset = try font.file.reader().readInt(u16, .big);
            const table: u32 = switch (lookup_type) {
                2 => lookup_table + subtable_offset,
                9 => ext: {
                    // lookup_type 9 is the GPOS extension table type, designed
                    // to hold offsets larger than 16-bit numbers can hold.
                    // This is ultimately a "link" to another table.
                    try font.file.seekTo(lookup_table + subtable_offset);
                    const ext_format = try font.file.reader().readInt(u16, .big);
                    debug.assert(ext_format == 1); // There is currently only one format
                    const ext_lookup_type = try font.file.reader().readInt(u16, .big);
                    // If we don't have a lookup type of 2 for our nested table
                    // we can skip the rest of the subtables, as each
                    // collection of tables in a single extension lookup table
                    // must share the same type.
                    if (ext_lookup_type != 2) break :lookup_subtables;

                    const extension_offset = try font.file.reader().readInt(u32, .big);
                    break :ext lookup_table + subtable_offset + extension_offset;
                },
                else => unreachable,
            };
            try font.file.seekTo(table);
            const pos_format = try font.file.reader().readInt(u16, .big);
            const coverage_offset = try font.file.reader().readInt(u16, .big);
            const coverage_index = try getCoverageIndex(font, table + coverage_offset, current);
            if (coverage_index == -1) continue;

            switch (pos_format) {
                1 => {
                    try font.file.seekTo(table + 4);
                    const value_format_1 = try font.file.reader().readInt(u16, .big);
                    const value_format_2 = try font.file.reader().readInt(u16, .big);
                    if (value_format_1 == 4 and value_format_2 == 0) { // Support more formats?
                        const value_record_pair_size_in_bytes: u32 = 2;
                        const pair_set_count = try font.file.reader().readInt(u16, .big);
                        try font.file.seekTo(table + 10 + 2 * @as(u32, @intCast(coverage_index)));
                        const pair_pos_offset = try font.file.reader().readInt(u16, .big);
                        const pair_value_table = table + pair_pos_offset;
                        try font.file.seekTo(pair_value_table);
                        const pair_value_count = try font.file.reader().readInt(u16, .big);
                        const pair_value_array = pair_value_table + 2;

                        if (coverage_index >= pair_set_count) return 0;

                        const needle = next;
                        var r: i32 = pair_value_count - 1;
                        var l: i32 = 0;

                        // Binary search.
                        while (l <= r) {
                            const m = (l + r) >> 1;
                            const pair_value = pair_value_array +
                                (2 + value_record_pair_size_in_bytes) * @as(u32, @intCast(m));
                            try font.file.seekTo(pair_value);
                            const second_glyph = try font.file.reader().readInt(u16, .big);
                            const straw = second_glyph;
                            if (needle < straw)
                                r = m - 1
                            else if (needle > straw)
                                l = m + 1
                            else
                                return try font.file.reader().readInt(i16, .big);
                        }
                    } else return 0;
                },
                2 => {
                    try font.file.seekTo(table + 4);
                    const value_format_1 = try font.file.reader().readInt(u16, .big);
                    const value_format_2 = try font.file.reader().readInt(u16, .big);
                    if (value_format_1 == 4 and value_format_2 == 0) { // Support more formats?
                        const class_def_1_offset = try font.file.reader().readInt(u16, .big);
                        const class_def_2_offset = try font.file.reader().readInt(u16, .big);
                        const glyph_1_class = try getGlyphClass(font, table + class_def_1_offset, current);
                        const glyph_2_class = try getGlyphClass(font, table + class_def_2_offset, next);

                        try font.file.seekTo(table + 12);
                        const class_1_count = try font.file.reader().readInt(u16, .big);
                        const class_2_count = try font.file.reader().readInt(u16, .big);

                        if (glyph_1_class < 0 or glyph_1_class >= class_1_count) return 0; // malformed
                        if (glyph_2_class < 0 or glyph_2_class >= class_2_count) return 0; // malformed

                        const class_1_records = table + 16;
                        const class_2_records = class_1_records + 2 *
                            (@as(u32, @intCast(glyph_1_class)) * @as(u32, @intCast(class_2_count)));
                        try font.file.seekTo(class_2_records + 2 * @as(u32, @intCast(glyph_2_class)));
                        return try font.file.reader().readInt(i16, .big);
                    } else return 0;
                },
                else => return 0, // Unsupported position format
            }
        }
    }

    return 0;
}

fn getCoverageIndex(font: *Font, coverage_table_offset: u32, glyph: u32) Font.FileError!i32 {
    try font.file.seekTo(coverage_table_offset);
    const coverage_format = try font.file.reader().readInt(u16, .big);
    switch (coverage_format) {
        1 => {
            const glyph_count = try font.file.reader().readInt(u16, .big);
            // Binary search.
            var l: i32 = 0;
            var r: i32 = glyph_count - 1;
            const needle: i32 = @intCast(glyph);
            while (l <= r) {
                const glyph_array_offset = coverage_table_offset + 4;
                var glyph_id: u16 = undefined;
                const m = (l + r) >> 1;
                try font.file.seekTo(glyph_array_offset + 2 * @as(u32, @intCast(m)));
                glyph_id = try font.file.reader().readInt(u16, .big);
                const straw = glyph_id;
                if (needle < straw)
                    r = m - 1
                else if (needle > straw)
                    l = m + 1
                else
                    return m;
            }
        },
        2 => {
            const range_count = try font.file.reader().readInt(u16, .big);
            const range_array_offset = coverage_table_offset + 4;

            // Binary search.
            var l: i32 = 0;
            var r: i32 = range_count - 1;
            const needle: i32 = @intCast(glyph);
            while (l <= r) {
                const m = (l + r) >> 1;
                const range_record_offset = range_array_offset + 6 * @as(u32, @intCast(m));
                try font.file.seekTo(range_record_offset);
                const straw_start = try font.file.reader().readInt(u16, .big);
                const straw_end = try font.file.reader().readInt(u16, .big);
                if (needle < straw_start)
                    r = m - 1
                else if (needle > straw_end)
                    l = m + 1
                else {
                    try font.file.seekTo(range_record_offset + 4);
                    const start_coverage_index = try font.file.reader().readInt(u16, .big);
                    return start_coverage_index + @as(i32, @intCast(glyph)) - straw_start;
                }
            }
        },
        else => return -1, // Unsupported/invalid coverage format
    }

    return -1; // Not found
}

fn getGlyphClass(font: *Font, class_def_table_offset: u32, glyph: u32) Font.FileError!i32 {
    try font.file.seekTo(class_def_table_offset);
    const class_def_format = try font.file.reader().readInt(u16, .big);
    switch (class_def_format) {
        1 => {
            const start_glyph_id = try font.file.reader().readInt(u16, .big);
            const glyph_count = try font.file.reader().readInt(u16, .big);
            const class_def_1_value_array = class_def_table_offset + 6;
            if (glyph >= start_glyph_id and glyph < start_glyph_id + glyph_count) {
                try font.file.seekTo(class_def_1_value_array + 2 * (glyph - start_glyph_id));
                return try font.file.reader().readInt(u16, .big);
            }
        },
        2 => {
            const class_range_count = try font.file.reader().readInt(u16, .big);
            const class_range_records = class_def_table_offset + 4;

            var l: i32 = 0;
            var r: i32 = class_range_count - 1;
            const needle = glyph;
            while (l <= r) {
                const m = (l + r) >> 1;
                const class_range_record = class_range_records + 6 * @as(u32, @intCast(m));
                try font.file.seekTo(class_range_record);
                const straw_start = try font.file.reader().readInt(u16, .big);
                const straw_end = try font.file.reader().readInt(u16, .big);
                if (needle < straw_start)
                    r = m - 1
                else if (needle > straw_end)
                    l = m + 1
                else
                    return try font.file.reader().readInt(u16, .big);
            }
        },
        else => return -1, // Unsupported/invalid class definition format
    }

    return -1;
}

/// Represents a font outline in path node form.
///
/// The font outline is similar in structure to a path, with the notable
/// difference being that curves in a font outline are quadratic, not cubic.
///
/// The purpose of the Outline abstraction is to read data in the "glyf" table
/// of a font and interpret it in a way that it can be quickly drawn using a
/// particular path set (with repeating codepoints cached). As such, the node
/// entries here are raw and relative and designed to be "played back" into a
/// Path with the particular transformations for font size, advance, and what
/// not set.
pub const Outline = struct {
    path: Path,
    x_min: i16,
    y_min: i16,
    x_max: i16,
    y_max: i16,

    /// Errors associated with outline initialization.
    pub const InitError = error{
        /// Malformed or corrupted outline data was found and the outline could not
        /// be properly parsed into a path.
        MalformedGlyph,
    } || Font.FileError || Path.Error || mem.Allocator.Error;

    /// deinit should be called to release the outline.
    pub fn init(alloc: mem.Allocator, font: *Font, glyph: Glyph) InitError!Outline {
        // Not supported when there is no outline detail
        debug.assert(glyph.outline != .none);

        // Get our dimensions ahead of time. We don't need to process the contour
        // count right now as we do that further down when plotting (so that we can
        // detect composite glyphs).
        try font.file.seekTo(glyph.outline.offset + 2);
        const x_min = try font.file.reader().readInt(i16, .big);
        const y_min = try font.file.reader().readInt(i16, .big);
        const x_max = try font.file.reader().readInt(i16, .big);
        const y_max = try font.file.reader().readInt(i16, .big);

        // Initialize a path for plotting
        var path: Path = .empty;
        errdefer path.deinit(alloc);

        // Apply some transformations when creating our outlines. This allows
        // us to apply simpler transformations later. What we are ultimately
        // doing here is making sure our y-axis is corrected from the upward
        // plane that fonts have to the downward one we have.
        path.transformation = path.transformation
            .scale(1.0, -1.0)
            .translate(0.0, @as(f64, @floatFromInt(font.meta.units_per_em)) * -1.0);
        defer path.transformation = Transformation.identity;

        // Plot the outline now; our inner routine can handle both simple and
        // composite glyphs recursively.
        try runOutline(alloc, font, &path, glyph.outline.offset);

        return .{
            .path = path,
            .x_min = x_min,
            .y_min = y_min,
            .x_max = x_max,
            .y_max = y_max,
        };
    }

    fn runOutline(alloc: mem.Allocator, font: *Font, path: *Path, glyf_offset: u32) InitError!void {
        // The local point representation (different than our floating-point
        // representation).
        const Point = struct {
            x: i16,
            y: i16,
        };

        // Flags for simple glyphs. Note we we may not necessarily use all values.
        const SimpleFlags = packed struct(u8) {
            on_curve: bool,
            x_short_vector: bool,
            y_short_vector: bool,
            repeat: bool,
            x_same_or_sign: bool,
            y_same_or_sign: bool,
            overlap_simple: bool,

            // We don't use the last 2 fields in the flags (OVERLAP_SIMPLE and the
            // reserved bit).
            unused: u1,
        };

        // Composite flags. Again, note we we may not necessarily use all values.
        const CompositeFlags = packed struct(u16) {
            args_are_words: bool,
            args_are_xy_values: bool,
            round_xy_to_grid: bool,
            we_have_a_scale: bool,

            unused_0x10: u1,

            more_components: bool,
            we_have_an_x_and_y_scale: bool,
            we_have_a_two_by_two: bool,
            we_have_instructions: bool,
            use_my_metrics: bool,
            overlap_compound: bool,
            scaled_component_offset: bool,
            unscaled_component_offset: bool,

            unused_remainder: u3,
        };

        // We only need number of contours here, so we can skip over the bounding
        // points after reading it.
        try font.file.seekTo(glyf_offset);
        const number_of_contours = try font.file.reader().readInt(i16, .big);
        try font.file.seekTo(glyf_offset + 10);

        if (number_of_contours < 0) {
            // This is a composite glyph; process each component recursively until
            // we're done, then just return.
            while (true) {
                const flags: CompositeFlags = @bitCast(try font.file.reader().readInt(u16, .big));
                const index = try font.file.reader().readInt(u16, .big);
                var x_offset: i16 = 0;
                var y_offset: i16 = 0;
                if (flags.args_are_words) {
                    x_offset = try font.file.reader().readInt(i16, .big);
                    y_offset = try font.file.reader().readInt(i16, .big);
                } else {
                    x_offset = @as(i8, @intCast(try font.file.reader().readByte()));
                    y_offset = @as(i8, @intCast(try font.file.reader().readByte()));
                }

                // Process the transformation
                const saved_ctm = path.transformation;
                defer path.transformation = saved_ctm;

                // Apply translate before scale if it's not... scaled ;p
                if (!flags.scaled_component_offset) {
                    path.transformation = path.transformation.translate(
                        @floatFromInt(x_offset),
                        @floatFromInt(y_offset),
                    );
                }

                if (flags.we_have_a_scale) {
                    const scale = parseF2Dot14(try font.file.reader().readInt(u16, .big));
                    path.transformation = path.transformation.scale(scale, scale);
                } else if (flags.we_have_an_x_and_y_scale) {
                    const sx = parseF2Dot14(try font.file.reader().readInt(u16, .big));
                    const sy = parseF2Dot14(try font.file.reader().readInt(u16, .big));
                    path.transformation = path.transformation.scale(sx, sy);
                } else if (flags.we_have_a_two_by_two) {
                    var m = Transformation.identity;
                    m.ax = parseF2Dot14(try font.file.reader().readInt(u16, .big));
                    m.cx = parseF2Dot14(try font.file.reader().readInt(u16, .big));
                    m.by = parseF2Dot14(try font.file.reader().readInt(u16, .big));
                    m.dy = parseF2Dot14(try font.file.reader().readInt(u16, .big));
                    path.transformation = path.transformation.mul(m);
                }

                // Apply translate after if it is scaled (opposite of above, if you
                // will).
                if (flags.scaled_component_offset) {
                    path.transformation = path.transformation.translate(
                        @floatFromInt(x_offset),
                        @floatFromInt(y_offset),
                    );
                }

                const return_pos = try font.file.getPos();

                // Lookup the glyph table entry and plot
                const glyph = try Glyph.byIndex(font, index);
                if (glyph.outline == .offset) {
                    try runOutline(alloc, font, path, glyph.outline.offset);
                }

                if (!flags.more_components) {
                    // No more composite glyphs, we can just return.
                    return;
                }

                // We have to manually seek here (no defer) so that we can catch
                // errors
                try font.file.seekTo(return_pos);
            }
        }

        // Rest of the routine here is for simple glyphs (and components of
        // composite glyphs).
        //
        // Set up our endpoints and initialize our temporary storage
        var end_points_of_contours: std.AutoHashMapUnmanaged(u16, void) = .empty;
        defer end_points_of_contours.deinit(alloc);

        var outline_len: u16 = 0;
        for (0..@intCast(number_of_contours)) |_| {
            const end_idx = try font.file.reader().readInt(u16, .big);
            try end_points_of_contours.put(alloc, end_idx, {});
            outline_len = end_idx + 1;
        }

        // Instructions are ignored and likely will be indefinitely, unless we need
        // it for something specific. I'm not anticipating it however as
        // stb_truetype does not use it, for example.
        {
            const instruction_length = try font.file.reader().readInt(u16, .big);
            try font.file.reader().skipBytes(instruction_length, .{});
        }

        // Pull in our flags
        var flags = try std.ArrayListUnmanaged(SimpleFlags).initCapacity(alloc, outline_len);
        defer flags.deinit(alloc);
        {
            var flag_idx: u16 = 0;
            while (flag_idx < outline_len) : (flag_idx += 1) {
                const read_flags: SimpleFlags = @bitCast(try font.file.reader().readByte());
                flags.appendAssumeCapacity(read_flags);
                if (read_flags.repeat) {
                    const repeat_count = try font.file.reader().readByte();
                    for (0..repeat_count) |_| {
                        flags.appendAssumeCapacity(read_flags);
                        flag_idx += 1;
                    }
                }
            }
        }

        // Set up our points. This is a two-pass situation, so we set up our ArrayList first.
        var points = try std.ArrayListUnmanaged(Point).initCapacity(alloc, outline_len);
        defer points.deinit(alloc);

        // Populate x-values
        {
            var current_point: i16 = 0;
            for (0..outline_len) |i| {
                if (flags.items[i].x_short_vector) {
                    if (flags.items[i].x_same_or_sign) {
                        current_point += try font.file.reader().readByte();
                    } else {
                        current_point -= try font.file.reader().readByte();
                    }
                } else if (!flags.items[i].x_same_or_sign) {
                    current_point += try font.file.reader().readInt(i16, .big);
                }

                points.appendAssumeCapacity(.{ .x = current_point, .y = 0 });
            }
        }

        // Do y-values now in a separate pass.
        {
            var current_point: i16 = 0;
            for (0..outline_len) |i| {
                if (flags.items[i].y_short_vector) {
                    if (flags.items[i].y_same_or_sign) {
                        current_point += try font.file.reader().readByte();
                    } else {
                        current_point -= try font.file.reader().readByte();
                    }
                } else if (!flags.items[i].y_same_or_sign) {
                    current_point += try font.file.reader().readInt(i16, .big);
                }

                points.items[i].y = current_point;
            }
        }

        {
            var state: enum {
                move_to,
                on_curve,
                off_curve,
            } = .move_to;

            var i: u16 = 0; // current index
            var j: u16 = 0; // initial index
            while (i < outline_len) : (i += 1) {
                sw: switch (state) {
                    .move_to => {
                        if (!flags.items[i].on_curve or end_points_of_contours.contains(i)) {
                            return error.MalformedGlyph;
                        }
                        try path.moveTo(
                            alloc,
                            @floatFromInt(points.items[i].x),
                            @floatFromInt(points.items[i].y),
                        );
                        j = i;
                        state = .on_curve;
                    },
                    .on_curve => {
                        if (!flags.items[i].on_curve) {
                            state = .off_curve;
                            break :sw;
                        }
                        try path.lineTo(
                            alloc,
                            @floatFromInt(points.items[i].x),
                            @floatFromInt(points.items[i].y),
                        );
                    },
                    .off_curve => {
                        if (flags.items[i].on_curve) {
                            try quadCurveTo(
                                alloc,
                                path,
                                points.items[i - 1].x,
                                points.items[i - 1].y,
                                points.items[i].x,
                                points.items[i].y,
                            );
                            state = .on_curve;
                            break :sw;
                        }
                        // We can handle cubic beziers (actually that's what we
                        // technically handle as can be seen by above, but it's
                        // actually more worthwhile for simplicity's sake to just
                        // sub-divide (lerp) the midpoint between our last
                        // off-curve point and this one, and plot a quadratic. This
                        // is also more correct for the TT/OT domain technically,
                        // as all curves are technically quadratic; it's just some
                        // fonts skip the endpoints that can be lerped from
                        // successive control points.
                        const end_x = (points.items[i].x + points.items[i - 1].x) >> 1;
                        const end_y = (points.items[i].y + points.items[i - 1].y) >> 1;
                        try quadCurveTo(
                            alloc,
                            path,
                            points.items[i - 1].x,
                            points.items[i - 1].y,
                            end_x,
                            end_y,
                        );
                    },
                }
                if (end_points_of_contours.contains(i)) {
                    if (state == .off_curve) {
                        // Curve back to our initial point
                        try quadCurveTo(
                            alloc,
                            path,
                            points.items[i].x,
                            points.items[i].y,
                            points.items[j].x,
                            points.items[j].y,
                        );
                    }
                    try path.close(alloc);
                    state = .move_to;
                }
            }
        }
    }

    pub fn deinit(self: *Outline, alloc: mem.Allocator) void {
        self.path.deinit(alloc);
    }

    /// "Appends", or replays, the stored path within the outline on the path supplied.
    ///
    /// One thing to note when using this function is to keep in mind that
    /// y-coordinates are already flipped, so it is not necessary (but rather
    /// incorrect) to pass a scale(1, -1) here.
    ///
    /// The path is expected to be not pre-allocated (i.e., we expand capacity when
    /// appending).
    pub fn appendToPath(
        self: *Outline,
        alloc: mem.Allocator,
        path: *Path,
    ) (Path.Error || mem.Allocator.Error)!void {
        for (self.path.nodes.items) |node| {
            switch (node) {
                .move_to => |n| try path.moveTo(alloc, n.point.x, n.point.y),
                .line_to => |n| try path.lineTo(alloc, n.point.x, n.point.y),
                .curve_to => |n| try path.curveTo(alloc, n.p1.x, n.p1.y, n.p2.x, n.p2.y, n.p3.x, n.p3.y),
                .close_path => try path.close(alloc),
            }
        }
    }

    fn quadCurveTo(
        alloc: mem.Allocator,
        path: *Path,
        control_x: i16,
        control_y: i16,
        to_x: i16,
        to_y: i16,
    ) (error{MalformedGlyph} || Path.Error || mem.Allocator.Error)!void {
        // NOTE: We take the current point here directly as we don't have a call to
        // do it right now. We also need to apply the inverse of the transformation
        // to get it in user space. If we add this to Path proper, we can just use
        // that instead.
        var x0 = (path.current_point orelse return error.MalformedGlyph).x;
        var y0 = (path.current_point orelse return error.MalformedGlyph).y;
        try path.transformation.deviceToUser(&x0, &y0);
        const x3: f64 = @floatFromInt(to_x);
        const y3: f64 = @floatFromInt(to_y);

        const x1 = x0 + 2.0 / 3.0 * (@as(f64, @floatFromInt(control_x)) - x0);
        const y1 = y0 + 2.0 / 3.0 * (@as(f64, @floatFromInt(control_y)) - y0);
        const x2 = x3 + 2.0 / 3.0 * (@as(f64, @floatFromInt(control_x)) - x3);
        const y2 = y3 + 2.0 / 3.0 * (@as(f64, @floatFromInt(control_y)) - y3);

        try path.curveTo(alloc, x1, y1, x2, y2, x3, y3);
    }

    fn parseF2Dot14(x: u16) f64 {
        return @as(f64, @floatFromInt(@as(i2, @bitCast(@as(u2, @intCast(x >> 14)))))) +
            @as(f64, @floatFromInt(x & 0x3FFF)) / 16384.0;
    }
};

test "Glyph.init" {
    const data = @embedFile("./internal/test-fonts/Inter-Regular.subset.ttf");
    const name = "Glyph.init";
    const cases = [_]struct {
        name: []const u8,
        codepoint: u21,
        expected: Glyph,
    }{
        .{
            .name = "basic",
            .codepoint = 'a',
            .expected = .{
                .index = 56,
                .advance = 1150,
                .lsb = 90,
                .outline = .{ .offset = 3256 },
            },
        },
        .{
            .name = "space",
            .codepoint = ' ',
            .expected = .{
                .index = 252,
                .advance = 576,
                .lsb = 0,
                .outline = .none,
            },
        },
        .{
            .name = "invalid",
            .codepoint = 0x10FFFD, // NOTE: will not work as expected if we have something in the PUA
            .expected = .{
                .index = 0,
                .advance = 1344,
                .lsb = 328,
                .outline = .{ .offset = 236 },
            },
        },
    };
    const TestFn = struct {
        fn f(tc: anytype) TestingError!void {
            var font: Font = Font.loadBuffer(data) catch |err| {
                debug.print("unexpected error from loadInternal: {}\n", .{err});
                return error.TestUnexpectedError;
            };
            try testing.expectEqualDeep(tc.expected, Glyph.init(&font, tc.codepoint));
        }
    };
    try runCases(name, cases, TestFn.f);
}

test "Glyph.Outline.parseF2Dot14" {
    try testing.expectEqual(1.99993896484375e0, Glyph.Outline.parseF2Dot14(0x7FFF));
    try testing.expectEqual(1.75, Glyph.Outline.parseF2Dot14(0x7000));
    try testing.expectEqual(0.00006103515625, Glyph.Outline.parseF2Dot14(0x0001));
    try testing.expectEqual(0.0, Glyph.Outline.parseF2Dot14(0x0));
    try testing.expectEqual(-0.00006103515625, Glyph.Outline.parseF2Dot14(0xffff));
    try testing.expectEqual(-2.0, Glyph.Outline.parseF2Dot14(0x8000));
}

test "Glyph.Outline.init" {
    const data = @embedFile("./internal/test-fonts/Inter-Regular.subset.ttf");
    const name = "Glyph.Outline.init";
    const cases = [_]struct {
        name: []const u8,
        codepoint: u21,
        expect_curve_to: bool,
    }{
        .{
            .name = "basic",
            .codepoint = 'a',
            .expect_curve_to = true,
        },
        .{
            .name = "composite",
            .codepoint = 'á',
            .expect_curve_to = true,
        },
        .{
            .name = "invalid",
            .codepoint = 0x10FFFD, // NOTE: will not work as expected if we have something in the PUA
            // Inter's "invalid char" glyph is more than just a box but still
            // has no curves.
            .expect_curve_to = false,
        },
    };
    const TestFn = struct {
        fn f(tc: anytype) TestingError!void {
            var font: Font = Font.loadBuffer(data) catch |err| {
                debug.print("unexpected error from loadInternal: {}\n", .{err});
                return error.TestUnexpectedError;
            };
            const glyph: Glyph = Glyph.init(&font, tc.codepoint) catch |err| {
                debug.print("unexpected error from Glyph.init: {}\n", .{err});
                return error.TestUnexpectedError;
            };
            var outline: Glyph.Outline = Glyph.Outline.init(testing.allocator, &font, glyph) catch |err| {
                debug.print("unexpected error from Glyph.Outline.init: {}\n", .{err});
                return error.TestUnexpectedError;
            };
            defer outline.deinit(testing.allocator);
            try testing.expect(outline.path.isClosed());
            var has_curve_to = false;
            for (outline.path.nodes.items) |node| {
                if (node == .curve_to) {
                    has_curve_to = true;
                }
            }
            try testing.expectEqual(tc.expect_curve_to, has_curve_to);
        }
    };
    try runCases(name, cases, TestFn.f);
}
