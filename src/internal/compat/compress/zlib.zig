const deflate = @import("flate/deflate.zig");

/// Compression level, trades between speed and compression size.
pub const Options = deflate.Options;

/// Compressor type
pub fn Compressor(comptime WriterType: type) type {
    return deflate.Compressor(.zlib, WriterType);
}

/// Create Compressor which outputs compressed data to the writer.
pub fn compressor(writer: anytype, options: Options) !Compressor(@TypeOf(writer)) {
    return try deflate.compressor(.zlib, writer, options);
}
