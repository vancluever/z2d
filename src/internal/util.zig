//! Utility package for miscellaneous functions.

const builtin = @import("std").builtin;
const debug = @import("std").debug;

const colorpkg = @import("../color.zig");

const vector_length = @import("../z2d.zig").vector_length;

/// Internal table test helper. Passes in an array of structs representing test
/// cases. "name" is the only expected field, otherwise it's entirely handled
/// by `f`.
pub fn runCases(name: []const u8, cases: anytype, f: *const fn (case: anytype) TestingError!void) !void {
    for (cases) |tc| {
        f(tc) catch |err| {
            debug.print("FAIL: {s}/{s}\n", .{ name, tc.name });
            return err;
        };
    }
}

/// Error union for `runCases`' test function. Must accommodate all of the
/// appropriate errors from the testing package in use.
pub const TestingError = error{
    TestUnexpectedError, // Use as placeholder for unexpected errors

    TestExpectedEqual,
    TestExpectedApproxEqAbs,
    TestUnexpectedResult,
    InvalidMatrix, // Transformation.Error.InvalidMatrix
    OutOfMemory, // std.mem.Allocator.Error
};

/// Internal vectorization function. Turns each field into a
/// `@Vector(vector_length, T)`, to allow for SIMD and ease of utilization by
/// the compositor.
pub fn vectorize(comptime T: type) type {
    var new_fields: [@typeInfo(T).@"struct".fields.len]builtin.Type.StructField = undefined;
    for (@typeInfo(T).@"struct".fields, 0..) |f, i| {
        new_fields[i] = .{
            .name = f.name,
            .type = @Vector(vector_length, f.type),
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(@Vector(vector_length, f.type)),
        };
    }
    return @Type(.{
        .@"struct" = .{
            .layout = .auto,
            .fields = &new_fields,
            .decls = &.{},
            .is_tuple = false,
        },
    });
}

/// Internal function for splatting, shorthand for
/// `@as(@Vector(vector_length, T), @splat(value))`.
pub fn splat(comptime T: type, value: anytype) @Vector(vector_length, T) {
    return @splat(value);
}

/// Internal function for vector gather, allows for array lookup via an index
/// of vectors.
///
/// Based on https://github.com/ziglang/zig/issues/12815#issuecomment-1243043038
pub fn gather(slice: anytype, index: anytype) @Vector(
    @typeInfo(@TypeOf(index)).vector.len,
    @typeInfo(@TypeOf(slice)).pointer.child,
) {
    const vector_len = @typeInfo(@TypeOf(index)).vector.len;
    const Elem = @typeInfo(@TypeOf(slice)).pointer.child;
    var result: [vector_len]Elem = undefined;
    comptime var vec_i = 0;
    inline while (vec_i < vector_len) : (vec_i += 1) {
        result[vec_i] = slice[index[vec_i]];
    }
    return result;
}

/// Short-hand splatted f32 zero values, used in multiple places.
pub const zero_float_vec = splat(f32, 0.0);

/// Short-hand splatted color zero values, used in multiple places.
pub const zero_color_vec: [vector_length]colorpkg.Color = zero_color_vec: {
    var result: [vector_length]colorpkg.Color = undefined;
    for (0..vector_length) |i| {
        result[i] = colorpkg.LinearRGB.init(0, 0, 0, 0).asColor();
    }
    break :zero_color_vec result;
};
