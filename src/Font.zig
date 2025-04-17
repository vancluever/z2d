// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024-2025 Chris Marchesi

//! Represents all static font data (loaded font based on family selection
//! data, table directory, metrics, etc), including any file handles associated
//! with the font.
//!
//! Font data must currently be loaded in from whole, single-font TTF files.
//! Interactions with font enumeration or substitution subsystems like
//! fontconfig are not supported - this means that the font file to be used
//! must be located ahead of time and contain all of the glyphs necessary to
//! render the desired text (no falling back to other fonts).
//!
//! Font collections are not supported; they may be in the future.
const Font = @This();

const debug = @import("std").debug;
const io = @import("std").io;
const fs = @import("std").fs;
const math = @import("std").math;
const mem = @import("std").mem;
const testing = @import("std").testing;

const runCases = @import("internal/util.zig").runCases;
const TestingError = @import("internal/util.zig").TestingError;

file: io.FixedBufferStream([]const u8),
dir: Directory,
meta: Meta,

/// Errors associated with loading a font from a file.
pub const LoadFileError = LoadBufferError ||
    fs.File.OpenError ||
    fs.File.Reader.Error ||
    mem.Allocator.Error ||
    error{StreamTooLong};

/// Loads and validates a font from a file.
///
/// The file is read in its entirety into memory. `deinit` must be called to
/// free the memory when you are finished with the font data.
pub fn loadFile(alloc: mem.Allocator, filename: []const u8) LoadFileError!Font {
    const file = try fs.cwd().openFile(filename, .{});
    defer file.close();
    const buffer = try file.reader().readAllAlloc(alloc, math.maxInt(u32));
    errdefer alloc.free(buffer);
    return loadBuffer(buffer);
}

/// Errors associated with loading a font from a buffer.
pub const LoadBufferError = ValidateMagicError || Directory.InitError || Meta.InitError;

/// Loads and validates a font from a buffer. Do not use `deinit` when using
/// this function, as it will produce illegal behavior.
pub fn loadBuffer(buffer: []const u8) LoadBufferError!Font {
    var file = io.fixedBufferStream(buffer);
    try validateMagic(&file);
    const dir = try Directory.init(&file);
    const meta = try Meta.init(&file, dir);
    // Reset our stream before we return it
    try file.seekTo(0);

    return .{
        .file = file,
        .dir = dir,
        .meta = meta,
    };
}

/// Frees the memory allocated when using `loadFile`. It's an illegal operation
/// to use this with `loadBuffer`.
pub fn deinit(self: *Font, alloc: mem.Allocator) void {
    alloc.free(self.file.buffer);
}

/// Errors associated with reading font file data, generally an alias for file
/// and stream read operations.
pub const FileError = error{EndOfStream};

/// Errors associated with validating the font file type.
const ValidateMagicError = error{
    /// The font file's magic number (first u32) does not match a supported
    /// format.
    InvalidFormat,
} || FileError;

fn validateMagic(file: *io.FixedBufferStream([]const u8)) ValidateMagicError!void {
    var header = [_]u8{0} ** 4;
    try file.reader().readNoEof(&header);
    var header_ok: bool = false;
    if (mem.eql(u8, &header, &.{ '1', 0, 0, 0 })) header_ok = true;
    if (mem.eql(u8, &header, "OTTO")) header_ok = true;
    if (mem.eql(u8, &header, &.{ 0, 1, 0, 0 })) header_ok = true;
    if (mem.eql(u8, &header, "true")) header_ok = true;

    if (!header_ok) return error.InvalidFormat;
}

/// Represents the table directory via offsets.
const Directory = struct {
    cmap: u32,
    glyf: u32,
    head: u32,
    hhea: u32,
    hmtx: u32,
    loca: u32,

    // Kerning tables (optional)
    kern: u32,
    GPOS: u32,

    /// Errors associated while loading the font table directory.
    const InitError = error{
        /// A checksum failure happened in the font file (e.g., when validating a
        /// table).
        ChecksumMismatch,

        /// A required table is missing in the font's directory.
        MissingRequiredTable,
    } || FileError;

    fn init(file: *io.FixedBufferStream([]const u8)) InitError!Directory {
        var result: Directory = result: {
            var r: Directory = undefined;
            inline for (@typeInfo(Directory).@"struct".fields) |f| {
                @field(r, f.name) = 0;
            }

            break :result r;
        };

        // Directory offsets are taken from the font start index
        // Note that we currently do not support font collections, so these are
        // the same as the beginning of the file
        const table_num_offset = 4;
        const table_dir_offset = 12;
        const table_dir_entry_len = 16;

        try file.seekTo(table_num_offset);
        const num_tables = try file.reader().readInt(u16, .big);

        try file.seekTo(table_dir_offset);

        for (0..num_tables) |dir_idx| {
            try file.seekTo(dir_idx * table_dir_entry_len + table_dir_offset);
            var entry_tag: [4]u8 = undefined;
            try file.reader().readNoEof(&entry_tag);
            inline for (@typeInfo(Directory).@"struct".fields) |f| {
                if (mem.eql(u8, &entry_tag, f.name)) {
                    const checksum: u32 = try file.reader().readInt(u32, .big);
                    const offset: u32 = try file.reader().readInt(u32, .big);
                    const len: u32 = try file.reader().readInt(u32, .big);

                    // Validate the checksum of the table. This is a simple
                    // addition of the u32 (padded) words in the table,
                    // discarding overflow.
                    // Note that due to the way the "head" table is written
                    // (which includes a checksum adjustment written after the
                    // directory is written), we need to assume a
                    // checksumAdjustment value of zero when calculating for
                    // the "head" table.
                    var actual_checksum: u32 = 0;
                    try file.seekTo(offset);
                    const is_head = mem.eql(u8, f.name, "head");
                    for (0..((len + 3) / 4)) |j| {
                        if (is_head and j == 2)
                            _ = try file.reader().readInt(u32, .big)
                        else
                            actual_checksum, _ = @addWithOverflow(
                                actual_checksum,
                                try file.reader().readInt(u32, .big),
                            );
                    }

                    if (checksum != actual_checksum) {
                        return error.ChecksumMismatch;
                    }

                    @field(result, f.name) = offset;
                }
            }
        }

        // We currently require all tables, so just go over them and make sure
        // all entries are present.
        inline for (@typeInfo(Directory).@"struct".fields) |f| {
            comptime {
                if (mem.eql(u8, f.name, "kern") or mem.eql(u8, f.name, "GPOS")) {
                    continue;
                }
            }

            if (@field(result, f.name) == 0) {
                return error.MissingRequiredTable;
            }
        }

        return result;
    }
};

/// Represents various metadata about the font that can be looked up ahead of
/// time.
const Meta = struct {
    const CmapSubtable = union(enum) {
        bmp: u32,
        full: u32,
    };

    const IndexToLocFormat = enum(u16) {
        short, // u16
        long, // u32
    };

    /// The type of the suitable cmap subtable that we found. We prefer the
    /// availability of a full repertoire table. Note that if the BMP is only
    /// supported, character ranges over U+FFFF will be unsupported and will be
    /// written as character 0 (unsupported block).
    cmap_subtable_offset: CmapSubtable,

    /// Denotes that the first phantom point (the left-side bearing point) is
    /// at x=0, found in the flags of the "head" table. When this is the case,
    /// xMin == lsb and we don't perform any more offsetting.
    lsb_is_at_x_zero: bool,

    /// The width of entries in the "loca" table.
    index_to_loc_format: IndexToLocFormat,

    /// The advanceWidthMax from the "hhea" table.
    advance_width_max: u16,

    /// The numberOfHMetrics from the "hhea" table,
    number_of_hmetrics: u16,

    /// The unitsPerEm value from the "head" table.
    units_per_em: u16,

    /// Errors associated with loading font file metadata.
    const InitError = error{
        /// No suitable cmap subtable could be found to load glyphs from.
        ///
        /// The "cmap" table must have one of the following subtables to work:
        ///
        /// * Unicode encoding (platform type 0): BMP (encoding type 3) or full
        /// (encoding type 4), or:
        ///
        /// * Windows encoding (platform type 3): BMP (encoding type 1) or full
        /// (encoding type 10).
        ///
        /// All other types are currently not supported by the library.
        NoSuitableCmapSubtable,

        /// The indexToLocFormat entry in the "head" table is an unsupported
        /// value (neither 0 or 1). This likely means that the font is
        /// corrupted.
        InvalidIndexToLocFormat,
    } || FileError;

    fn init(file: *io.FixedBufferStream([]const u8), dir: Directory) InitError!Meta {
        const cmap_subtable_offset: CmapSubtable = cmap_subtable_offset: {
            // We don't really do a lot of hard work here to look for the table; we
            // just look for either Windows or Unicode platform with the appropriate
            // encoding, which will then either give us a type 4 or type 12 subtable,
            // which will be the kind that we return. We return the first match.
            var bmp_offset: u32 = 0;
            var full_offset: u32 = 0;

            const table_num_offset = dir.cmap + 2;

            const encoding_platform_unicode = 0;
            const encoding_platform_windows = 3;

            const unicode_encoding_bmp = 3;
            const unicode_encoding_full = 4;

            const windows_encoding_bmp = 1;
            const windows_encoding_full = 10;

            try file.seekTo(table_num_offset);
            const num_tables = try file.reader().readInt(u16, .big);

            for (0..num_tables) |_| {
                const platform_id = try file.reader().readInt(u16, .big);
                const encoding_id = try file.reader().readInt(u16, .big);
                const subtable_offset = try file.reader().readInt(u32, .big) + dir.cmap;

                if (platform_id == encoding_platform_unicode) {
                    switch (encoding_id) {
                        unicode_encoding_bmp => bmp_offset = subtable_offset,
                        unicode_encoding_full => full_offset = subtable_offset,
                        else => continue,
                    }
                }

                if (platform_id == encoding_platform_windows) {
                    switch (encoding_id) {
                        windows_encoding_bmp => bmp_offset = subtable_offset,
                        windows_encoding_full => full_offset = subtable_offset,
                        else => continue,
                    }
                }
            }

            break :cmap_subtable_offset if (full_offset != 0)
                .{ .full = full_offset }
            else if (bmp_offset != 0)
                .{ .bmp = bmp_offset }
            else
                return error.NoSuitableCmapSubtable;
        };

        const head_flags = dir.head + 14;
        const units_per_em_offset = dir.head + 18;
        const index_to_loc_format_offset = dir.head + 50;
        try file.seekTo(head_flags);
        const lsb_is_at_x_zero: bool = @bitCast(@as(
            u1,
            @intCast(try file.reader().readInt(u16, .big) & 2 >> 1),
        ));
        try file.seekTo(index_to_loc_format_offset);
        const index_to_loc_format = try file.reader().readInt(u16, .big);
        try file.seekTo(units_per_em_offset);
        const units_per_em = try file.reader().readInt(u16, .big);

        const advance_width_max_offset = dir.hhea + 10;
        const number_of_hmetrics_offset = dir.hhea + 34;
        try file.seekTo(advance_width_max_offset);
        const advance_width_max = try file.reader().readInt(u16, .big);
        try file.seekTo(number_of_hmetrics_offset);
        const number_of_hmetrics = try file.reader().readInt(u16, .big);

        return .{
            .cmap_subtable_offset = cmap_subtable_offset,
            .lsb_is_at_x_zero = lsb_is_at_x_zero,
            .index_to_loc_format = switch (index_to_loc_format) {
                0 => .short,
                1 => .long,
                else => return error.InvalidIndexToLocFormat,
            },
            .advance_width_max = advance_width_max,
            .number_of_hmetrics = number_of_hmetrics,
            .units_per_em = units_per_em,
        };
    }
};

test "Font.loadFile, loadBuffer" {
    const name = "Font.loadFile, loadBuffer";
    const cases = [_]struct {
        name: []const u8,
        path: []const u8,
        expected_directory: Directory,
        expected_meta: Meta,
    }{
        .{
            .name = "basic",
            // Note: unlike the embeds in other tests, this lookup assumes cwd
            // is the project root. This will possibly fail if running outside
            // of it, and is done for simplicity's sake - I don't want to have
            // to ship any sort of cwd info or what not down here from
            // build.zig just for testing purposes. Just run this using
            // "zig build test". :P
            .path = "src/internal/test-fonts/Inter-Regular.subset.ttf",
            .expected_directory = .{
                .cmap = 18720,
                .glyf = 236,
                .head = 17364,
                .hhea = 18588,
                .hmtx = 17420,
                .loca = 16776,
                .kern = 0,
                .GPOS = 19724,
            },
            .expected_meta = .{
                .cmap_subtable_offset = .{ .bmp = 18740 },
                .lsb_is_at_x_zero = true,
                .index_to_loc_format = .short,
                .advance_width_max = 5492,
                .number_of_hmetrics = 292,
                .units_per_em = 2048,
            },
        },
    };
    const TestFn = struct {
        fn f(tc: anytype) TestingError!void {
            var actual: Font = loadFile(
                testing.allocator,
                tc.path,
            ) catch |err| {
                debug.print("unexpected error from loadBuffer: {}\n", .{err});
                return error.TestUnexpectedError;
            };
            defer actual.deinit(testing.allocator);
            try testing.expectEqualDeep(tc.expected_directory, actual.dir);
            try testing.expectEqualDeep(tc.expected_meta, actual.meta);
        }
    };
    try runCases(name, cases, TestFn.f);
}
