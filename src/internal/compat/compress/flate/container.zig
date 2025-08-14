//! Container of the deflate bit stream body. Container adds header before
//! deflate bit stream and footer after. It can bi gzip, zlib or raw (no header,
//! no footer, raw bit stream).
//!
//! Zlib format is defined in rfc 1950. Header has 2 bytes and footer 4 bytes
//! addler 32 checksum.
//!
//! Gzip format is defined in rfc 1952. Header has 10+ bytes and footer 4 bytes
//! crc32 checksum and 4 bytes of uncompressed data length.
//!
//!
//! rfc 1950: https://datatracker.ietf.org/doc/html/rfc1950#page-4
//! rfc 1952: https://datatracker.ietf.org/doc/html/rfc1952#page-5
//!

const std = @import("std");

pub const Container = enum {
    raw, // no header or footer
    zlib, // zlib header and footer

    pub fn size(w: Container) usize {
        return headerSize(w) + footerSize(w);
    }

    pub fn headerSize(w: Container) usize {
        return switch (w) {
            .zlib => 2,
            .raw => 0,
        };
    }

    pub fn footerSize(w: Container) usize {
        return switch (w) {
            .zlib => 4,
            .raw => 0,
        };
    }

    pub const list = [_]Container{ .raw, .gzip, .zlib };

    pub const Error = error{
        BadZlibHeader,
        WrongZlibChecksum,
    };

    pub fn writeHeader(comptime wrap: Container, writer: anytype) !void {
        switch (wrap) {
            .zlib => {
                // ZLIB has a two-byte header (https://datatracker.ietf.org/doc/html/rfc1950#page-4):
                // 1st byte:
                //  - First four bits is the CINFO (compression info), which is 7 for the default deflate window size.
                //  - The next four bits is the CM (compression method), which is 8 for deflate.
                // 2nd byte:
                //  - Two bits is the FLEVEL (compression level). Values are: 0=fastest, 1=fast, 2=default, 3=best.
                //  - The next bit, FDICT, is set if a dictionary is given.
                //  - The final five FCHECK bits form a mod-31 checksum.
                //
                // CINFO = 7, CM = 8, FLEVEL = 0b10, FDICT = 0, FCHECK = 0b11100
                const zlibHeader = [_]u8{ 0x78, 0b10_0_11100 };
                try writer.writeAll(&zlibHeader);
            },
            .raw => {},
        }
    }

    pub fn writeFooter(comptime wrap: Container, hasher: *Hasher(wrap), writer: anytype) !void {
        var bits: [4]u8 = undefined;
        switch (wrap) {
            .zlib => {
                // ZLIB (RFC 1950) is big-endian, unlike GZIP (RFC 1952).
                // 4 bytes of ADLER32 (Adler-32 checksum)
                // Checksum value of the uncompressed data (excluding any
                // dictionary data) computed according to Adler-32
                // algorithm.
                std.mem.writeInt(u32, &bits, hasher.chksum(), .big);
                try writer.writeAll(&bits);
            },
            .raw => {},
        }
    }

    pub fn parseHeader(comptime wrap: Container, reader: anytype) !void {
        switch (wrap) {
            .zlib => try parseZlibHeader(reader),
            .raw => {},
        }
    }

    fn parseZlibHeader(reader: anytype) !void {
        const cm = try reader.read(u4);
        const cinfo = try reader.read(u4);
        _ = try reader.read(u8);
        if (cm != 8 or cinfo > 7) {
            return error.BadZlibHeader;
        }
    }

    pub fn parseFooter(comptime wrap: Container, hasher: *Hasher(wrap), reader: anytype) !void {
        switch (wrap) {
            .zlib => {
                const chksum: u32 = @byteSwap(hasher.chksum());
                if (try reader.read(u32) != chksum) return error.WrongZlibChecksum;
            },
            .raw => {},
        }
    }

    pub fn Hasher(comptime wrap: Container) type {
        const HasherType = switch (wrap) {
            .zlib => std.hash.Adler32,
            .raw => struct {
                pub fn init() @This() {
                    return .{};
                }
            },
        };

        return struct {
            hasher: HasherType = switch (wrap) {
                .zlib => .{},
                inline else => HasherType.init(),
            },
            bytes: usize = 0,

            const Self = @This();

            pub fn update(self: *Self, buf: []const u8) void {
                switch (wrap) {
                    .raw => {},
                    else => {
                        self.hasher.update(buf);
                        self.bytes += buf.len;
                    },
                }
            }

            pub fn chksum(self: *Self) u32 {
                switch (wrap) {
                    .raw => return 0,
                    .zlib => return self.hasher.adler,
                }
            }

            pub fn bytesRead(self: *Self) u32 {
                return @truncate(self.bytes);
            }
        };
    }
};
