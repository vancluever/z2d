// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024 Chris Marchesi
//   Copyright © 2002 University of Southern California
//
// Portions of the code in this file have been derived and adapted from the
// Cairo project (https://www.cairographics.org/), notably cairo-slope.c.

//! Slope represents a slope, de-constructed as its deltas.
const Slope = @This();

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
    // Do basic comparison first. Our comparison is done multiplicatively
    // on the vector (saves division, allows for calculation of things like
    // clockwise/counterclockwise direction, etc).
    const cmp = math.sign(a.dy * b.dx - b.dy * a.dx);
    if (cmp != 0) {
        return @intFromFloat(cmp);
    }

    // Handle special cases where our comparison is zero (tie breakers).

    // Zero vectors all compare equal, and more positive than any non-zero
    // vector.
    if (a.dx == 0 and a.dy == 0 and b.dx == 0 and b.dy == 0) return 0;
    if (a.dx == 0 and a.dy == 0) return 1;
    if (b.dx == 0 and b.dy == 0) return -1;

    // Handler logic for vectors that are either equal to pi or differ by
    // exactly pi. Note our current f64 implementation probably makes these
    // cases infinitesimally rare, especially the latter case. When/if we
    // move to fixed point, this will be more likely, and we can optimize
    // for that.
    //
    // We check if we need to do comparison by checking for the sign (note
    // in Cairo, this is done using XOR on the sign bit, not too sure if
    // this would be faster than math.sign on fixed point or not).
    if (math.sign(a.dx) != math.sign(b.dx) or math.sign(a.dy) != math.sign(b.dy)) {
        // In this case, a is always considered less than b.
        return if (a.dx > 0 or (a.dx == 0 and a.dy > 0)) -1 else 1;
    }

    // If we've got here, are truly identical and can be returned as 0.
    return 0;
}
