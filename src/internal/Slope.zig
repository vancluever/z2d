// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024-2025 Chris Marchesi
//   Copyright © 2002 University of Southern California
//
// Portions of the code in this file have been derived and adapted from the
// Cairo project (https://www.cairographics.org/), notably cairo-slope.c and
// cairo-path-stroke-polygon.c.

//! Slope represents a slope, de-constructed as its deltas.
const Slope = @This();

const debug = @import("std").debug;
const math = @import("std").math;

const Point = @import("Point.zig");

dx: f64,
dy: f64,

/// Initializes a slope vector as b - a.
pub fn init(a: Point, b: Point) Slope {
    return .{
        .dx = b.x - a.x,
        .dy = b.y - a.y,
    };
}

/// Checks to see if a slope is equal to another slope.
pub fn equal(self: Slope, other: Slope) bool {
    return self.dx == other.dx and self.dy == other.dy;
}

/// Returns the calculated slope as dy/dx.
pub fn calculate(self: Slope) f64 {
    return self.dy / self.dx;
}

/// Performs slope comparison. The comparison is always done based on the
/// smaller angular difference between them (i.e., less than pi).
///
/// Returns:
///
///   * < 0 when a is less than b
///   * == 0 when a is the same as b
///   * > 0 when a is larger than b
pub fn compare(a: Slope, b: Slope) i32 {
    // We snap our b slope to our a slope if the differences are below the f64
    // epsilon. This ensures downstream calculations that depend on slopes
    // being non-parallel do not produce undefined behavior or NaNs.
    const bdy = if (@abs(b.dy - a.dy) > math.floatEps(f64)) b.dy else a.dy;
    const bdx = if (@abs(b.dx - a.dx) > math.floatEps(f64)) b.dx else a.dx;

    // Do basic comparison first. Our comparison is done multiplicatively
    // on the vector (saves division, allows for calculation of things like
    // clockwise/counterclockwise direction, etc).
    const cmp = math.sign(a.dy * bdx - bdy * a.dx);
    if (cmp != 0) {
        return @intFromFloat(cmp);
    }

    // Handle special cases where our comparison is zero (tie breakers).

    // Zero vectors all compare equal, and more positive than any non-zero
    // vector.
    if (a.dx == 0 and a.dy == 0 and bdx == 0 and bdy == 0) return 0;
    if (a.dx == 0 and a.dy == 0) return 1;
    if (bdx == 0 and bdy == 0) return -1;

    // Handler logic for vectors that are either equal to pi or differ by
    // exactly pi. Note our current f64 implementation probably makes these
    // cases infinitesimally rare, especially the latter case. When/if we
    // move to fixed point, this will be more likely, and we can optimize
    // for that.
    //
    // We check if we need to do comparison by checking for the sign (note
    // in Cairo, this is done using XOR on the sign bit, not too sure if
    // this would be faster than math.sign on fixed point or not).
    if (math.sign(a.dx) != math.sign(bdx) or math.sign(a.dy) != math.sign(bdy)) {
        // In this case, a is always considered less than b.
        return if (a.dx > 0 or (a.dx == 0 and a.dy > 0)) -1 else 1;
    }

    // If we've got here, are truly identical and can be returned as 0.
    return 0;
}

/// Takes the dot product of two slopes (normalization is done for you) for
/// purposes of miter limit comparison.
///
/// This is based on the following proof, which can be seen in various places
/// in the Cairo codebase, including cairo-stroke-polygon.c:
///
/// Consider the miter join formed when two line segments
/// meet at an angle psi:
///
///       /.\
///      /. .\
///     /./ \.\
///    /./psi\.\
///
/// We can zoom in on the right half of that to see:
///
///        |\
///        | \ psi/2
///        |  \
///        |   \
///        |    \
///        |     \
///      miter    \
///     length     \
///        |        \
///        |        .\
///        |    .     \
///        |.   line   \
///         \    width  \
///          \           \
///
///
/// The right triangle in that figure, (the line-width side is
/// shown faintly with three '.' characters), gives us the
/// following expression relating miter length, angle and line
/// width:
///
///    1 /sin (psi/2) = miter_length / line_width
///
/// The right-hand side of this relationship is the same ratio
/// in which the miter limit (ml) is expressed. We want to know
/// when the miter length is within the miter limit. That is
/// when the following condition holds:
///
///    1/sin(psi/2) <= ml
///    1 <= ml sin(psi/2)
///    1 <= ml² sin²(psi/2)
///    2 <= ml² 2 sin²(psi/2)
///                2·sin²(psi/2) = 1-cos(psi)
///    2 <= ml² (1-cos(psi))
///
///                in · out = |in| |out| cos (psi)
///
/// in and out are both unit vectors, so:
///
///                in · out = cos (psi)
///
///    2 <= ml² (1 + in · out)
///
/// NOTE: The proof solution has a typo in Cairo, which you can usually easily
/// see given that it is immediately repeated in code after the comments; while
/// the code will read as above ("2 <= ml² (1 + in · out)"), the comments will
/// subtract one from the dot product instead.
pub fn compare_for_miter_limit(in_slope: Slope, out_slope: Slope, miter_limit: f64) bool {
    // Normalize our slopes, if not done already.
    //
    // TODO: This can probably be taken out. We never *not* normalize slopes
    // anymore, so if this is particularly costly it probably be removed (in
    // favor of setting the expectation that we always expect normalized slopes
    // here).
    const in_slope_normal = in_normal: {
        var s = in_slope;
        _ = s.normalize();
        break :in_normal s;
    };
    const out_slope_normal = out_normal: {
        var s = out_slope;
        _ = s.normalize();
        break :out_normal s;
    };

    // Take the dot product of our slopes
    const in_dot_out = in_slope_normal.dx * out_slope_normal.dx + in_slope_normal.dy * out_slope_normal.dy;

    return 2 <= miter_limit * miter_limit * (1 + in_dot_out);
}

/// Updates the slope normalized to the unit vector. Returns the magnitude (the
/// hypotenuse at the time of normalization, under non-special cases).
///
/// Take care when using this method with any other comparison methods (e.g.,
/// equal or compare); normalized slopes are only comparable with other slopes
/// and vice versa.
pub fn normalize(self: *Slope) f64 {
    var result_dx: f64 = undefined;
    var result_dy: f64 = undefined;
    var mag: f64 = undefined;

    debug.assert(self.dx != 0.0 or self.dy != 0.0);

    if (self.dx == 0.0) {
        result_dx = 0.0;
        if (self.dy > 0.0) {
            mag = self.dy;
            result_dy = 1.0;
        } else {
            mag = -self.dy;
            result_dy = -1.0;
        }
    } else if (self.dy == 0.0) {
        result_dy = 0.0;
        if (self.dx > 0.0) {
            mag = self.dx;
            result_dx = 1.0;
        } else {
            mag = -self.dx;
            result_dx = -1.0;
        }
    } else {
        mag = math.hypot(self.dx, self.dy);
        result_dx = self.dx / mag;
        result_dy = self.dy / mag;
    }

    self.dx = result_dx;
    self.dy = result_dy;
    return mag;
}
