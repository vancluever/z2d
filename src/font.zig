// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024-2026 Chris Marchesi

//! Contains abstractions for font and collection data required for drawing
//! text.
//!
//! Font data can currently be loaded in from whole, single-font
//! TrueType/OpenType files, or from font collection files (aka TTC/TrueType
//! Font Collection files).
//!
//! Interactions with font enumeration or substitution subsystems like
//! fontconfig are not supported - this means that the font file to be used
//! must be located ahead of time and contain all of the fonts and glyphs
//! necessary to render the desired text (no falling back to other fonts).

const std = @import("std");

const readerInt = @import("internal/util.zig").readerInt;
const readerSeek = @import("internal/util.zig").readerSeek;

/// Errors associated with reading font file data, generally an alias for file
/// and stream read operations.
pub const ReaderError = error{ InvalidSeek, EndOfStream, ReadFailed };

/// Represents a full collection of fonts, loaded from either a single-font
/// file (e.g., .otf, .ttf), or font collection file (.ttc).
pub const File = struct {
    /// The type of the font file.
    pub const Type = enum {
        /// A file containing a single font (.otf, .ttf, etc).
        single,

        /// A file containing a collection (.ttc, etc).
        collection,
    };

    /// The binary font data.
    buffer: []const u8,

    /// The number of fonts in the font file.
    num_fonts: union(Type) {
        single: void,
        collection: u32,
    },

    /// Errors associated with loading a font from a file.
    pub const LoadFileError = LoadBufferError || std.Io.Dir.ReadFileAllocError;

    /// Opens the font or font collection file at `filename` and loads its
    /// offsets.
    ///
    /// `deinit` must be called to free the memory when you are finished with
    /// the font data.
    pub fn loadFile(io: std.Io, alloc: std.mem.Allocator, filename: []const u8) LoadFileError!File {
        return loadBuffer(try std.Io.Dir.cwd().readFileAlloc(io, filename, alloc, .unlimited));
    }

    /// Errors associated with loading a font from a buffer.
    pub const LoadBufferError = DetectFileTypeError || ReaderError;

    /// Loads and validates a font from a buffer. Expects the font to be a single
    /// font file (collections are not supported).
    ///
    /// Do not use `deinit` when using this function, as it will produce illegal
    /// behavior.
    pub fn loadBuffer(buffer: []const u8) LoadBufferError!File {
        var file = std.Io.Reader.fixed(buffer);
        switch (try detectFileType(&file)) {
            .single => return .{ .buffer = buffer, .num_fonts = .single },
            .collection => {
                // Our file type detection will leave the reader at the
                // numFonts entry, so we can just read that in.
                const num_fonts = try readerInt(&file, u32, .big);
                return .{
                    .buffer = buffer,
                    .num_fonts = .{ .collection = num_fonts },
                };
            },
        }
    }

    /// Frees the memory allocated when using `loadFile`. It's an illegal operation
    /// to use this with `loadBuffer`.
    pub fn deinit(self: *File, alloc: std.mem.Allocator) void {
        alloc.free(self.buffer);
        self.* = undefined;
    }

    /// Errors associated with loading a font from the file.
    pub const LoadFontIndexError = error{
        /// The index is out of range of the amount of fonts in the file.
        IndexOutOfRange,
    } || ReaderError || Font.LoadBufferOffsetError;

    /// Retrieves the font at `index` in the file. Performs checksum validation
    /// on the data.
    pub fn loadFontIndex(self: *const File, index: u32) LoadFontIndexError!Font {
        const offset: u32 = switch (self.num_fonts) {
            .single => single: {
                if (index != 0) {
                    return error.IndexOutOfRange;
                }
                break :single 0;
            },
            .collection => |num_fonts| collection: {
                if (index > num_fonts - 1) {
                    return error.IndexOutOfRange;
                }
                var reader: std.Io.Reader = .fixed(self.buffer);
                try readerSeek(&reader, 12 + 4 * index);
                break :collection try readerInt(&reader, u32, .big);
            },
        };

        return try Font.loadBufferOffset(self.buffer, offset);
    }

    /// Errors associated with validating the font file type.
    const DetectFileTypeError = error{
        /// The font file's magic number (first u32) does not match a supported
        /// format.
        InvalidFormat,
    } || ReaderError;

    fn detectFileType(file: *std.Io.Reader) DetectFileTypeError!Type {
        var header = [_]u8{0} ** 4;
        try file.readSliceAll(&header);

        // Font files

        if (std.mem.eql(u8, &header, &.{ '1', 0, 0, 0 })) return .single;
        if (std.mem.eql(u8, &header, "OTTO")) return .single;
        if (std.mem.eql(u8, &header, &.{ 0, 1, 0, 0 })) return .single;
        if (std.mem.eql(u8, &header, "true")) return .single;

        // Font collections
        if (std.mem.eql(u8, &header, "ttcf")) {
            // Validate the major/minor versions to ensure that they are of the
            // versions that we support.
            const major_version = try readerInt(file, u16, .big);
            const minor_version = try readerInt(file, u16, .big);
            if ((major_version == 1 or major_version == 2) and minor_version == 0) {
                return .collection;
            }
        }

        // Invalid or unrecognized format
        return error.InvalidFormat;
    }
};

/// Represents all static font data (loaded font based on family selection
/// data, table directory, metrics, etc), including any file handles associated
/// with the font.
pub const Font = struct {
    file: std.Io.Reader,
    dir: Directory,
    meta: Meta,

    /// Errors associated with loading a font from a buffer and selected offset.
    pub const LoadBufferOffsetError = ReaderError || Directory.InitError || Meta.InitError;

    /// Loads and validates a font from the supplied `buffer`, at the supplied
    /// `offset`. For single-font files, the offset should always be zero.
    ///
    /// Note that other than the checksum verification and the requirement for
    /// certain tables, there are no guarantees on this function with regards
    /// to correctness. Choosing the incorrect offset is likely to result in
    /// undefined behavior. It is recommended to use the functionality within
    /// `File` instead, which supplies a higher-level interface.
    pub fn loadBufferOffset(buffer: []const u8, offset: u32) LoadBufferOffsetError!Font {
        var file = std.Io.Reader.fixed(buffer);
        try readerSeek(&file, offset);
        const dir = try Directory.init(&file);
        const meta = try Meta.init(&file, dir);
        // Reset our stream before we return it
        try readerSeek(&file, 0);

        return .{
            .file = file,
            .dir = dir,
            .meta = meta,
        };
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
        } || ReaderError;

        fn init(file: *std.Io.Reader) InitError!Directory {
            var result: Directory = result: {
                var r: Directory = undefined;
                inline for (@typeInfo(Directory).@"struct".fields) |f| {
                    @field(r, f.name) = 0;
                }

                break :result r;
            };

            // Directory offsets are taken from the font start index
            const font_start_offset = file.seek;
            const table_num_offset = 4;
            const table_dir_offset = 12;
            const table_dir_entry_len = 16;

            try readerSeek(file, font_start_offset + table_num_offset);
            const num_tables = try readerInt(file, u16, .big);

            try readerSeek(file, table_dir_offset);

            for (0..num_tables) |dir_idx| {
                try readerSeek(file, dir_idx * table_dir_entry_len + font_start_offset + table_dir_offset);
                var entry_tag: [4]u8 = undefined;
                try file.readSliceAll(&entry_tag);
                inline for (@typeInfo(Directory).@"struct".fields) |f| {
                    if (std.mem.eql(u8, &entry_tag, f.name)) {
                        const checksum: u32 = try readerInt(file, u32, .big);
                        const offset: u32 = try readerInt(file, u32, .big);
                        const len: u32 = try readerInt(file, u32, .big);

                        // Validate the checksum of the table. This is a simple
                        // addition of the u32 (padded) words in the table,
                        // discarding overflow.
                        // Note that due to the way the "head" table is written
                        // (which includes a checksum adjustment written after the
                        // directory is written), we need to assume a
                        // checksumAdjustment value of zero when calculating for
                        // the "head" table.
                        var actual_checksum: u32 = 0;
                        try readerSeek(file, offset); // Table offsets are always absolute
                        const is_head = std.mem.eql(u8, f.name, "head");
                        for (0..((len + 3) / 4)) |j| {
                            if (is_head and j == 2)
                                _ = try readerInt(file, u32, .big)
                            else
                                actual_checksum, _ = @addWithOverflow(
                                    actual_checksum,
                                    try readerInt(file, u32, .big),
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
                    if (std.mem.eql(u8, f.name, "kern") or std.mem.eql(u8, f.name, "GPOS")) {
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
        } || ReaderError;

        fn init(file: *std.Io.Reader, dir: Directory) InitError!Meta {
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

                try readerSeek(file, table_num_offset);
                const num_tables = try readerInt(file, u16, .big);

                for (0..num_tables) |_| {
                    const platform_id = try readerInt(file, u16, .big);
                    const encoding_id = try readerInt(file, u16, .big);
                    const subtable_offset = try readerInt(file, u32, .big) + dir.cmap;

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
            try readerSeek(file, head_flags);
            const lsb_is_at_x_zero: bool = @bitCast(@as(
                u1,
                @intCast(try readerInt(file, u16, .big) & 2 >> 1),
            ));
            try readerSeek(file, index_to_loc_format_offset);
            const index_to_loc_format = try readerInt(file, u16, .big);
            try readerSeek(file, units_per_em_offset);
            const units_per_em = try readerInt(file, u16, .big);

            const advance_width_max_offset = dir.hhea + 10;
            const number_of_hmetrics_offset = dir.hhea + 34;
            try readerSeek(file, advance_width_max_offset);
            const advance_width_max = try readerInt(file, u16, .big);
            try readerSeek(file, number_of_hmetrics_offset);
            const number_of_hmetrics = try readerInt(file, u16, .big);

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
};

test "Font.loadBufferOffset" {
    const actual: Font = try .loadBufferOffset(TestSingleFont.data, 0);
    try std.testing.expectEqualDeep(TestSingleFont.expected.directory, actual.dir);
    try std.testing.expectEqualDeep(TestSingleFont.expected.meta, actual.meta);
}

test "File.loadFile, loadBuffer, loadFontIndex e2e (single font)" {
    // NOTE: This test assumes cwd is the project root. This will possibly fail
    // if running outside of it, and is done for simplicity's sake - I don't
    // want to have to ship any sort of cwd info or what not down here from
    // build.zig just for testing purposes. Just run this using "zig build
    // test". :P
    var file: File = try .loadFile(std.testing.io, std.testing.allocator, TestSingleFont.filename);
    defer file.deinit(std.testing.allocator);
    const actual: Font = try file.loadFontIndex(0);
    try std.testing.expectEqualDeep(TestSingleFont.expected.directory, actual.dir);
    try std.testing.expectEqualDeep(TestSingleFont.expected.meta, actual.meta);
}

test "File.loadBuffer, loadFontIndex e2e (font collection)" {
    var file: File = try .loadBuffer(TestFontCollection.data);
    const actual_regular: Font = try file.loadFontIndex(0);
    try std.testing.expectEqualDeep(TestFontCollection.expected_regular.directory, actual_regular.dir);
    try std.testing.expectEqualDeep(TestFontCollection.expected_regular.meta, actual_regular.meta);
    const actual_bold: Font = try file.loadFontIndex(1);
    try std.testing.expectEqualDeep(TestFontCollection.expected_bold.directory, actual_bold.dir);
    try std.testing.expectEqualDeep(TestFontCollection.expected_bold.meta, actual_bold.meta);
}

test "File.loadFontIndex, out of range error cases" {
    {
        const file: File = try .loadBuffer(TestSingleFont.data);
        try std.testing.expectError(error.IndexOutOfRange, file.loadFontIndex(1));
    }
    {
        const file: File = try .loadBuffer(TestFontCollection.data);
        try std.testing.expectError(error.IndexOutOfRange, file.loadFontIndex(2));
    }
}

test "File.detectFileType, invalid format" {
    var invalid_file: std.Io.Reader = .fixed("NFNT"); // aka Not A Font ;)
    try std.testing.expectError(error.InvalidFormat, File.detectFileType(&invalid_file));
}

const TestExpectedFontTableMeta = struct {
    directory: Font.Directory,
    meta: Font.Meta,
};

const TestSingleFont = struct {
    const path = "internal/test-fonts/Inter-Regular.subset.ttf";
    const filename = "src/" ++ path;
    const data = @embedFile(path);
    const expected: TestExpectedFontTableMeta = .{
        .directory = .{
            .cmap = 18720,
            .glyf = 236,
            .head = 17364,
            .hhea = 18588,
            .hmtx = 17420,
            .loca = 16776,
            .kern = 0,
            .GPOS = 19724,
        },
        .meta = .{
            .cmap_subtable_offset = .{ .bmp = 18740 },
            .lsb_is_at_x_zero = true,
            .index_to_loc_format = .short,
            .advance_width_max = 5492,
            .number_of_hmetrics = 292,
            .units_per_em = 2048,
        },
    };
};

const TestFontCollection = struct {
    const data = @embedFile("internal/test-fonts/Inter-Regular-Bold.subset.ttc");
    const expected_regular: TestExpectedFontTableMeta = .{
        .directory = .{
            .cmap = 8504,
            .glyf = 304,
            .head = 8084,
            .hhea = 8372,
            .hmtx = 8140,
            .loca = 7964,
            .kern = 0,
            .GPOS = 13112,
        },
        .meta = .{
            .cmap_subtable_offset = .{ .bmp = 8524 },
            .lsb_is_at_x_zero = true,
            .index_to_loc_format = .short,
            .advance_width_max = 2018,
            .number_of_hmetrics = 58,
            .units_per_em = 2048,
        },
    };
    const expected_bold: TestExpectedFontTableMeta = .{
        .directory = .{
            .cmap = 8504,
            .glyf = 15744,
            .head = 23580,
            .hhea = 23868,
            .hmtx = 23636,
            .loca = 23460,
            .kern = 0,
            .GPOS = 24644,
        },
        .meta = .{
            .cmap_subtable_offset = .{ .bmp = 8524 },
            .lsb_is_at_x_zero = true,
            .index_to_loc_format = .short,
            .advance_width_max = 2125,
            .number_of_hmetrics = 58,
            .units_per_em = 2048,
        },
    };
};
