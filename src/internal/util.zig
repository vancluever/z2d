//! Utility package for miscellaneous functions.

const builtin = @import("std").builtin;
const debug = @import("std").debug;

const vector_length = @import("../compositor.zig").vector_length;

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
    TestExpectedEqual,
    TestExpectedApproxEqAbs,
    InvalidMatrix, // Transformation.Error.InvalidMatrix
};

/// Internal vectorization function. Turns each field into a
/// `@Vector(vector_length, T)`, to allow for SIMD and ease of utilization by
/// the compositor.
pub fn vectorize(comptime T: type) type {
    var new_fields: [@typeInfo(T).Struct.fields.len]builtin.Type.StructField = undefined;
    for (@typeInfo(T).Struct.fields, 0..) |f, i| {
        new_fields[i] = .{
            .name = f.name,
            .type = @Vector(vector_length, f.type),
            .default_value = null,
            .is_comptime = false,
            .alignment = @alignOf(@Vector(vector_length, f.type)),
        };
    }
    return @Type(.{
        .Struct = .{
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
