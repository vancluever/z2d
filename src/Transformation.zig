//! A Transformation represents an affine transformation matrix.
//!
//! We use named parameters, as outlined below:
//!
//! ```
//! [ ax by tx ]
//! [ cx dy ty ]
//! [  0  0  1 ]
//! ```
//!
//! Since all named operations operate on the named fields using the assumption
//! of the affine transformation matrix, more complex operations (such as
//! `inverse`) should be safe, so long as you stick to these methods and don't
//! use `mul`. Checks are still made on functions that are possibly unsafe,
//! however, to ensure that a matrix is valid before execution. Any operation
//! that would fail due to a result of this will fail with an `InvalidMatrix`
//! error.
const Transformation = @This();

const math = @import("std").math;
const testing = @import("std").testing;

const Point = @import("internal/Point.zig");

/// Errors associated with matrix transformation operations.
pub const Error = error{
    /// The matrix is invalid for the specific operation.
    InvalidMatrix,
};

ax: f64,
by: f64,
cx: f64,
dy: f64,
tx: f64,
ty: f64,

/// Represents the identity matrix; a matrix or point multiplied by this matrix
/// yields the original.
pub const identity: Transformation = .{
    .ax = 1,
    .by = 0,
    .cx = 0,
    .dy = 1,
    .tx = 0,
    .ty = 0,
};

/// Returns `true` if the two matrices are equal.
pub fn equal(a: Transformation, b: Transformation) bool {
    return a.ax == b.ax and
        a.by == b.by and
        a.cx == b.cx and
        a.dy == b.dy and
        a.tx == b.tx and
        a.ty == b.ty;
}

/// Computes the determinant of the matrix.
///
/// Note that the determinant of an affine transformation matrix reduces to a
/// simple ad - bc.
pub fn determinant(a: Transformation) f64 {
    return a.ax * a.dy - a.by * a.cx;
}

/// Multiplies a transformation matrix with another.
pub fn mul(a: Transformation, b: Transformation) Transformation {
    // [ a.ax a.by a.tx ] [ b.ax b.by b.tx ]
    // [ a.cx a.dy a.ty ] [ b.cx b.dy b.ty ] ·
    // [    0    0    1 ] [    0    0    1 ]
    //
    // =
    //
    // [ (a.ax * b.ax + a.by * b.cx) (a.ax * b.by + a.by * b.dy) (a.ax * b.tx + a.by * b.ty + a.tx) ]
    // [ (a.cx * b.ax + a.dy * b.cx) (a.cx * b.by + a.dy * b.dy) (a.cx * b.tx + a.dy * b.ty + a.ty) ]
    // [                          0                           0                                  1  ]
    //

    return .{
        .ax = a.ax * b.ax + a.by * b.cx,
        .by = a.ax * b.by + a.by * b.dy,
        .cx = a.cx * b.ax + a.dy * b.cx,
        .dy = a.cx * b.by + a.dy * b.dy,
        .ty = a.cx * b.tx + a.dy * b.ty + a.ty,
        .tx = a.ax * b.tx + a.by * b.ty + a.tx,
    };
}

fn mulScalar(a: Transformation, x: f64) Transformation {
    return .{
        .ax = a.ax * x,
        .by = a.by * x,
        .cx = a.cx * x,
        .dy = a.dy * x,
        .ty = a.ty * x,
        .tx = a.tx * x,
    };
}

/// Returns the inverse of this Transformation matrix. `InvalidMatrix` is
/// returned if the matrix is not invertible.
pub fn inverse(a: Transformation) Error!Transformation {
    // Determine some special cases first (scale + translate only, or translate
    // only).
    if (a.by == 0 and a.cx == 0) {
        if (a.ax == 0 or a.dy == 0) {
            return error.InvalidMatrix; // We can't invert the determinant
        } else if (a.ax != 1 or a.dy != 1) {
            // Scale + translate, this is the more complex case, but can be
            // ultimately reduced to some simple calculations due to the fact
            // our determinant is only ad (no -bc).
            return .{
                .ax = 1 / a.ax,
                .by = 0,
                .cx = 0,
                .dy = 1 / a.dy,
                .tx = -a.tx / a.ax,
                .ty = -a.ty / a.dy,
            };
        } else {
            // The simpler case where since both a and d are 1, we're only left
            // with negating translations.
            return .{
                .ax = 1,
                .by = 0,
                .cx = 0,
                .dy = 1,
                .tx = -a.tx,
                .ty = -a.ty,
            };
        }
    }

    // Neither of the special cases apply, so we need to do the more complex
    // inverse. However, the inverse of the transformation matrix can be
    // simplified from the general case quite a bit.
    //
    // For example, the determinant reduces to the standard ad - bc, so let's do that first.
    const det = a.determinant();
    if (det == 0) {
        return error.InvalidMatrix; // We can't invert the determinant
    }

    // We can just short-circuit to our adjunct below according to what the
    // transpose of the cofactor is ultimately reduced to. Note this holds as
    // the last position in the augmented translate (i.e., 3,3) is ad - bc too,
    // which divided by our determinant is 1, and the rest of the row is 0,
    // which gives us our standard [0, 0, 1] bottom row.
    const adjunct: Transformation = .{
        .ax = a.dy,
        .by = -a.by,
        .cx = -a.cx,
        .dy = a.ax,
        .tx = a.by * a.ty - a.dy * a.tx,
        .ty = a.cx * a.tx - a.ax * a.ty,
    };

    // Finally, just multiply by 1 / det.
    return adjunct.mulScalar(1 / det);
}

/// Apply a co-ordinate offset to the origin.
pub fn translate(a: Transformation, tx: f64, ty: f64) Transformation {
    var b = identity;
    b.tx = tx;
    b.ty = ty;
    return a.mul(b);
}

/// Scale by (`sx`, `sy`). When `sx` and `sy` are not equal, a stretching
/// effect will be achieved.
pub fn scale(a: Transformation, sx: f64, sy: f64) Transformation {
    var b = identity;
    b.ax = sx;
    b.dy = sy;
    return a.mul(b);
}

/// Rotate around the origin by `angle` (in radians).
pub fn rotate(a: Transformation, angle: f64) Transformation {
    var b = identity;
    const s = @sin(angle);
    const c = @cos(angle);
    b.ax = c;
    b.by = -s;
    b.cx = s;
    b.dy = c;
    return a.mul(b);
}

/// Applies the transformation matrix to the supplied `x` and `y`, but ignores
/// translation.
pub fn userToDeviceDistance(a: Transformation, x: *f64, y: *f64) void {
    const in_x = x.*;
    const in_y = y.*;
    x.* = a.ax * in_x + a.by * in_y;
    y.* = a.cx * in_x + a.dy * in_y;
}

/// Applies the transformation matrix to the supplied `x` and `y`.
pub fn userToDevice(a: Transformation, x: *f64, y: *f64) void {
    a.userToDeviceDistance(x, y);
    x.* += a.tx;
    y.* += a.ty;
}

/// Applies the inverse of the transformation matrix to the supplied `x` and
/// `y`, but ignores translation.
pub fn deviceToUserDistance(a: Transformation, x: *f64, y: *f64) Error!void {
    (try a.inverse()).userToDeviceDistance(x, y);
}

/// Applies the inverse of the transformation matrix to the supplied `x` and
/// `y`.
pub fn deviceToUser(a: Transformation, x: *f64, y: *f64) Error!void {
    (try a.inverse()).userToDevice(x, y);
}

test "equal" {
    const a: Transformation = .{
        .ax = 1,
        .by = 2,
        .cx = 3,
        .dy = 4,
        .tx = 5,
        .ty = 6,
    };

    const b: Transformation = .{
        .ax = 7,
        .by = 8,
        .cx = 9,
        .dy = 10,
        .tx = 11,
        .ty = 12,
    };

    try testing.expect(a.equal(a));
    try testing.expect(!a.equal(b));
}

test "determinant" {
    const a: Transformation = .{
        .ax = 1,
        .by = 2,
        .cx = 3,
        .dy = 4,
        .tx = 5,
        .ty = 6,
    };

    try testing.expectEqual(-2, a.determinant());
}

test "mul" {
    const a: Transformation = .{
        .ax = 1,
        .by = 2,
        .cx = 3,
        .dy = 4,
        .tx = 5,
        .ty = 6,
    };

    const b: Transformation = .{
        .ax = 7,
        .by = 8,
        .cx = 9,
        .dy = 10,
        .tx = 11,
        .ty = 12,
    };

    const expected: Transformation = .{
        .ax = 25,
        .by = 28,
        .cx = 57,
        .dy = 64,
        .tx = 40,
        .ty = 87,
    };

    try testing.expectEqualDeep(expected, a.mul(b));
}

test "mulScalar" {
    const a: Transformation = .{
        .ax = 1,
        .by = 2,
        .cx = 3,
        .dy = 4,
        .tx = 5,
        .ty = 6,
    };

    const expected: Transformation = .{
        .ax = 3,
        .by = 6,
        .cx = 9,
        .dy = 12,
        .tx = 15,
        .ty = 18,
    };

    try testing.expectEqualDeep(expected, a.mulScalar(3));
}

test "inverse" {
    {
        // Special case (scale + translate)
        const a: Transformation = .{
            .ax = 2,
            .by = 0,
            .cx = 0,
            .dy = 3,
            .tx = 10,
            .ty = 15,
        };

        const expected: Transformation = .{
            .ax = 0.5,
            .by = 0,
            .cx = 0,
            .dy = 1.0 / 3.0,
            .tx = -5,
            .ty = -5,
        };

        try testing.expectEqualDeep(expected, a.inverse());
    }

    {
        // Special case (translate only)
        const a: Transformation = .{
            .ax = 1,
            .by = 0,
            .cx = 0,
            .dy = 1,
            .tx = 10,
            .ty = 15,
        };

        const expected: Transformation = .{
            .ax = 1,
            .by = 0,
            .cx = 0,
            .dy = 1,
            .tx = -10,
            .ty = -15,
        };

        try testing.expectEqualDeep(expected, a.inverse());
    }

    {
        // Full case
        const a: Transformation = .{
            .ax = 2,
            .by = 7,
            .cx = 5,
            .dy = 3,
            .tx = 10,
            .ty = 15,
        };

        const expected: Transformation = .{
            .ax = -3.0 / 29.0,
            .by = 7.0 / 29.0,
            .cx = 5.0 / 29.0,
            .dy = -2.0 / 29.0,
            .tx = -75.0 / 29.0,
            .ty = -20.0 / 29.0,
        };

        // FIXME: see roundf64 comments for details on why we need to round
        // test results.
        try testing.expectEqualDeep(roundf64(expected), roundf64(try (a.inverse())));
    }

    {
        // Invalid special-case matrix
        try testing.expectError(error.InvalidMatrix, (Transformation{
            .ax = 0,
            .by = 0,
            .cx = 0,
            .dy = 0,
            .tx = 0,
            .ty = 0,
        }).inverse());
    }

    {
        // Invalid standard-case matrix
        try testing.expectError(error.InvalidMatrix, (Transformation{
            .ax = 3,
            .by = 3,
            .cx = 3,
            .dy = 3,
            .tx = 0,
            .ty = 0,
        }).inverse());
    }
}

test "translate" {
    try testing.expectEqualDeep(Transformation{
        .ax = 1,
        .by = 0,
        .cx = 0,
        .dy = 1,
        .tx = 10,
        .ty = 15,
    }, identity.translate(10, 15));
}

test "scale" {
    try testing.expectEqualDeep(Transformation{
        .ax = 2,
        .by = 0,
        .cx = 0,
        .dy = 3,
        .tx = 0,
        .ty = 0,
    }, identity.scale(2, 3));
}

test "rotate" {
    const angle = math.pi / 2.0;
    const s = @sin(angle);
    const c = @cos(angle);
    try testing.expectEqualDeep(Transformation{
        .ax = c,
        .by = -s,
        .cx = s,
        .dy = c,
        .tx = 0,
        .ty = 0,
    }, identity.rotate(angle));
}

test "userToDevice" {
    // These tests are much less superficial than the basic
    // translate/rotate/scale tests above as we operate on real co-ordinates.
    {
        // Basic tests
        const orig_x: f64 = 2;
        const orig_y: f64 = 3;

        // Identity
        var got_x = orig_x;
        var got_y = orig_y;
        identity.userToDevice(&got_x, &got_y);
        try testing.expectEqual(2, got_x);
        try testing.expectEqual(3, got_y);
        // Translate
        got_x = orig_x;
        got_y = orig_y;
        identity.translate(10, 12).userToDevice(&got_x, &got_y);
        try testing.expectEqual(12, got_x);
        try testing.expectEqual(15, got_y);
        // Scale
        got_x = orig_x;
        got_y = orig_y;
        identity.scale(10, 20).userToDevice(&got_x, &got_y);
        try testing.expectEqual(20, got_x);
        try testing.expectEqual(60, got_y);
    }

    {
        // Rotate
        var x: f64 = 9;
        var y: f64 = 0;
        const want_x: f64 = 0;
        const want_y: f64 = 9;
        identity.rotate(math.pi / 2.0).userToDevice(&x, &y);
        // FIXME: see roundf64 comments for details on why we need to round
        // test results.
        x = @round(x);
        y = @round(y);
        try testing.expectEqual(want_x, x);
        try testing.expectEqual(want_y, y);
    }

    {
        // Combined
        var x: f64 = 9;
        var y: f64 = 0;
        const want_x: f64 = -200;
        const want_y: f64 = 190;
        identity.rotate(math.pi / 2.0).scale(10, 10).translate(10, 20).userToDevice(&x, &y);
        try testing.expectEqual(want_x, x);
        try testing.expectEqual(want_y, y);
    }
}

test "deviceToUser" {
    const original_x: f64 = 9;
    const original_y: f64 = 0;
    const want_x: f64 = -200;
    const want_y: f64 = 190;
    const t = identity.rotate(math.pi / 2.0).scale(10, 10).translate(10, 20);
    var got_x = original_x;
    var got_y = original_y;
    t.userToDevice(&got_x, &got_y);
    try testing.expectEqual(want_x, got_x);
    try testing.expectEqual(want_y, got_y);
    try t.deviceToUser(&got_x, &got_y);
    try testing.expectEqual(original_x, got_x);
    try testing.expectEqual(original_y, got_y);
}

test "userToDeviceDistance" {
    {
        // Basic tests
        const orig_x: f64 = 2;
        const orig_y: f64 = 3;

        // Identity
        var got_x = orig_x;
        var got_y = orig_y;
        identity.userToDeviceDistance(&got_x, &got_y);
        try testing.expectEqual(2, got_x);
        try testing.expectEqual(3, got_y);
        // Translate
        got_x = orig_x;
        got_y = orig_y;
        identity.translate(10, 12).userToDeviceDistance(&got_x, &got_y);
        try testing.expectEqual(2, got_x);
        try testing.expectEqual(3, got_y);
        // Scale
        got_x = orig_x;
        got_y = orig_y;
        identity.scale(10, 20).userToDeviceDistance(&got_x, &got_y);
        try testing.expectEqual(20, got_x);
        try testing.expectEqual(60, got_y);
    }

    {
        // Rotate
        var x: f64 = 9;
        var y: f64 = 0;
        const want_x: f64 = 0;
        const want_y: f64 = 9;
        identity.rotate(math.pi / 2.0).userToDeviceDistance(&x, &y);
        // FIXME: see roundf64 comments for details on why we need to round
        // test results.
        x = @round(x);
        y = @round(y);
        try testing.expectEqual(want_x, x);
        try testing.expectEqual(want_y, y);
    }

    {
        // Combined
        var x: f64 = 9;
        var y: f64 = 2;
        const want_x: f64 = -20;
        const want_y: f64 = 90;
        identity.rotate(math.pi / 2.0).scale(10, 10).translate(10, 20).userToDeviceDistance(&x, &y);
        // FIXME: see roundf64 comments for details on why we need to round
        // test results.
        x = @round(x);
        y = @round(y);
        try testing.expectEqual(want_x, x);
        try testing.expectEqual(want_y, y);
    }
}

test "deviceToUserDistance" {
    const original_x: f64 = 9;
    const original_y: f64 = 2;
    const want_x: f64 = -20;
    const want_y: f64 = 90;
    const t = identity.rotate(math.pi / 2.0).scale(10, 10).translate(10, 20);
    var got_x = original_x;
    var got_y = original_y;
    t.userToDeviceDistance(&got_x, &got_y);
    // FIXME: see roundf64 comments for details on why we need to round
    // test results.
    got_x = @round(got_x);
    got_y = @round(got_y);
    try testing.expectEqual(want_x, got_x);
    try testing.expectEqual(want_y, got_y);
    try t.deviceToUserDistance(&got_x, &got_y);
    got_x = @round(got_x);
    got_y = @round(got_y);
    try testing.expectEqual(original_x, got_x);
    try testing.expectEqual(original_y, got_y);
}

/// For testing only. Rounds each element in the matrix to 16 significant
/// digits.
fn roundf64(a: Transformation) Transformation {
    // FIXME: Notes on rounding issues (some apply to exactly this helper, some
    // don't)
    //
    // Some transformations and multiplications seem to be yielding some very
    // small fractional discrepancies (e.g., to the tune of e-15 or more) on
    // what you would otherwise expect as whole numbers, or in comparison to
    // say expected results expressed as fractional expressions in tests (the
    // latter situation is why the function in which this comment resides
    // exists). We are rounding some test results to work around this. This
    // could just be the nature of floating point, but I'd like to do another
    // pass after the initial implementation push to double-check, after which
    // we can fix and/or delete this message.
    //
    //
    // Applies to this function: inconsistent f64 precision rounding has been
    // observed in the inverse in some situations; specifically, we express
    // expected test results as fraction expressions, which is where the
    // mismatch happens. Funny enough we've gotten *more* precision when
    // applying the inverse (17 significant digits) than what we get when doing
    // just straight division using comptime_float -> f64 coercion (16
    // significant digits). Not too sure why, but for now this exists to just
    // help work around it.
    return .{
        .ax = roundf64_field(a.ax),
        .by = roundf64_field(a.by),
        .cx = roundf64_field(a.cx),
        .dy = roundf64_field(a.dy),
        .tx = roundf64_field(a.tx),
        .ty = roundf64_field(a.ty),
    };
}

fn roundf64_field(a: f64) f64 {
    // https://stackoverflow.com/a/13094362 (CC BY-SA 3.0)
    if (a == 0) {
        return 0;
    }
    const b = math.pow(f64, 10, 16 - @ceil(math.log10(@abs(a))));
    return @round(a * b) / b;
}
