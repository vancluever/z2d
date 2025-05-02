// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024-2025 Chris Marchesi
//   Copyright © 2002 University of Southern California
//
// Portions of the code in this file have been derived and adapted from the
// Cairo project (https://www.cairographics.org/), notably cairo-arc.c and
// cairo-matrix.c.

const math = @import("std").math;
const debug = @import("std").debug;

const options = @import("../options.zig");

const PathVTable = @import("PathVTable.zig");
const Transformation = @import("../Transformation.zig");

const max_full_circles = 65536;

// arc_error_normalized and arc_max_angle_for_tolerance_normalized are used for
// determining the largest angle that can be used in our arc segment splines
// within our set error tolerance.
//
// Spline deviation from the circle in radius would be given by:
//
//      error = sqrt (x**2 + y**2) - 1
//
// A simpler error function to work with is:
//
//      e = x**2 + y**2 - 1
//
// From "Good approximation of circles by curvature-continuous Bezier
// curves", Tor Dokken and Morten Daehlen, Computer Aided Geometric
// Design 8 (1990) 22-41, we learn:
//
//      abs (max(e)) = 4/27 * sin**6(angle/4) / cos**2(angle/4)
//
// and
//      abs (error) =~ 1/2 * e

fn arc_error_normalized(angle: f64) f64 {
    return 2.0 / 27.0 * math.pow(f64, @sin(angle / 4), 6) / math.pow(f64, @cos(angle / 4), 2);
}

fn arc_max_angle_for_tolerance_normalized(tolerance: f64) f64 {
    // Use table lookup to reduce search time in most cases.
    const table = [_]struct {
        angle: f64,
        err: f64,
    }{
        .{ .angle = math.pi / 1.0, .err = 0.0185185185185185036127 },
        .{ .angle = math.pi / 2.0, .err = 0.000272567143730179811158 },
        .{ .angle = math.pi / 3.0, .err = 2.38647043651461047433e-05 },
        .{ .angle = math.pi / 4.0, .err = 4.2455377443222443279e-06 },
        .{ .angle = math.pi / 5.0, .err = 1.11281001494389081528e-06 },
        .{ .angle = math.pi / 6.0, .err = 3.72662000942734705475e-07 },
        .{ .angle = math.pi / 7.0, .err = 1.47783685574284411325e-07 },
        .{ .angle = math.pi / 8.0, .err = 6.63240432022601149057e-08 },
        .{ .angle = math.pi / 9.0, .err = 3.2715520137536980553e-08 },
        .{ .angle = math.pi / 10.0, .err = 1.73863223499021216974e-08 },
        .{ .angle = math.pi / 11.0, .err = 9.81410988043554039085e-09 },
    };

    // this value is chosen arbitrarily. this gives an error of about 1.74909e-20
    const max_segments = 1000;

    for (0..table.len) |i| {
        if (table[i].err < tolerance) return table[i].angle;
    }

    var angle: f64 = undefined;
    for (table.len..max_segments) |i| {
        angle = math.pi / @as(f64, @floatFromInt(i));
        const err = arc_error_normalized(angle);
        if (err <= tolerance) {
            break;
        }
    }

    return angle;
}

fn arc_segments_needed(angle: f64, radius: f64, ctm: Transformation, tolerance: f64) i32 {
    // the error is amplified by at most the length of the circle.
    const major_axis = transformed_circle_major_axis(ctm, radius);
    const max_angle = arc_max_angle_for_tolerance_normalized(tolerance / major_axis);

    return @intFromFloat(@ceil(@abs(angle) / max_angle));
}

/// determine the length of the major axis of a circle of the given radius
/// after applying the transformation matrix.
pub fn transformed_circle_major_axis(matrix: Transformation, radius: f64) f64 {
    // This lengthy explanation was taken from the comments above the
    // implementation of Cairo's _cairo_matrix_transformed_circle_major_axis in
    // cairo-matrix.c. I've preserved it in its entirety just to have it close to
    // the code as it's an important piece to understanding how we use the CTM to
    // calculate the major axis.
    //
    // A circle in user space is transformed into an ellipse in device space.
    //
    // The following is a derivation of a formula to calculate the length of the
    // major axis for this ellipse; this is useful for error bounds calculations.
    //
    // Thanks to Walter Brisken <wbrisken@aoc.nrao.edu> for this derivation:
    //
    // 1.  First some notation:
    //
    // All capital letters represent vectors in two dimensions.  A prime '
    // represents a transformed coordinate.  Matrices are written in underlined
    // form, ie _R_.  Lowercase letters represent scalar real values.
    //
    // 2.  The question has been posed:  What is the maximum expansion factor
    // achieved by the linear transformation
    //
    // X' = X _R_
    //
    // where _R_ is a real-valued 2x2 matrix with entries:
    //
    // _R_ = [a b]
    //       [c d]  .
    //
    // In other words, what is the maximum radius, MAX[ |X'| ], reached for any
    // X on the unit circle ( |X| = 1 ) ?
    //
    // 3.  Some useful formulae
    //
    // (A) through (C) below are standard double-angle formulae.  (D) is a lesser
    // known result and is derived below:
    //
    // (A)  sin²(θ) = (1 - cos(2*θ))/2
    // (B)  cos²(θ) = (1 + cos(2*θ))/2
    // (C)  sin(θ)*cos(θ) = sin(2*θ)/2
    // (D)  MAX[a*cos(θ) + b*sin(θ)] = sqrt(a² + b²)
    //
    // Proof of (D):
    //
    // find the maximum of the function by setting the derivative to zero:
    //
    //      -a*sin(θ)+b*cos(θ) = 0
    //
    // From this it follows that
    //
    //      tan(θ) = b/a
    //
    // and hence
    //
    //      sin(θ) = b/sqrt(a² + b²)
    //
    // and
    //
    //      cos(θ) = a/sqrt(a² + b²)
    //
    // Thus the maximum value is
    //
    //      MAX[a*cos(θ) + b*sin(θ)] = (a² + b²)/sqrt(a² + b²)
    //                                  = sqrt(a² + b²)
    //
    // 4.  Derivation of maximum expansion
    //
    // To find MAX[ |X'| ] we search brute force method using calculus.  The unit
    // circle on which X is constrained is to be parameterized by t:
    //
    //      X(θ) = (cos(θ), sin(θ))
    //
    // Thus
    //
    //      X'(θ) = X(θ) * _R_ = (cos(θ), sin(θ)) * [a b]
    //                                              [c d]
    //            = (a*cos(θ) + c*sin(θ), b*cos(θ) + d*sin(θ)).
    //
    // Define
    //
    //      r(θ) = |X'(θ)|
    //
    // Thus
    //
    //      r²(θ) = (a*cos(θ) + c*sin(θ))² + (b*cos(θ) + d*sin(θ))²
    //            = (a² + b²)*cos²(θ) + (c² + d²)*sin²(θ)
    //                + 2*(a*c + b*d)*cos(θ)*sin(θ)
    //
    // Now apply the double angle formulae (A) to (C) from above:
    //
    //      r²(θ) = (a² + b² + c² + d²)/2
    //         + (a² + b² - c² - d²)*cos(2*θ)/2
    //      + (a*c + b*d)*sin(2*θ)
    //            = f + g*cos(φ) + h*sin(φ)
    //
    // Where
    //
    //      f = (a² + b² + c² + d²)/2
    //      g = (a² + b² - c² - d²)/2
    //      h = (a*c + d*d)
    //      φ = 2*θ
    //
    // It is clear that MAX[ |X'| ] = sqrt(MAX[ r² ]).  Here we determine MAX[ r² ]
    // using (D) from above:
    //
    //      MAX[ r² ] = f + sqrt(g² + h²)
    //
    // And finally
    //
    //      MAX[ |X'| ] = sqrt( f + sqrt(g² + h²) )
    //
    // Which is the solution to this problem.
    //
    // Walter Brisken
    // 2004/10/08
    //
    // (Note that the minor axis length is at the minimum of the above solution,
    // which is just sqrt ( f - sqrt(g² + h²) ) given the symmetry of (D)).
    //
    //
    // For another derivation of the same result, using Singular Value Decomposition,
    // see doc/tutorial/src/singular.c.
    const a: f64 = matrix.ax;
    const b: f64 = matrix.by;
    const c: f64 = matrix.cx;
    const d: f64 = matrix.dy;
    var f: f64 = undefined;
    var g: f64 = undefined;
    var h: f64 = undefined;
    var i: f64 = undefined;
    var j: f64 = undefined;

    // Unrolled and abridged _cairo_matrix_has_unity_scale here. Checks if the
    // matrix is only 90 degree rotations or flips.
    const has_unity_scale: bool = _has_unity_scale: {
        // Possible FIXME if things break here. This is derived from expanding
        // Cairo's SCALING_EPSILON manually since we don't use fixed point;
        // it's possible that "close to zero" in Cairo means "zero" for us due
        // to this.
        //
        // This is ultimately the minimum value within Cairo's 24.8 fixed-point
        // notation (1/256).
        const scaling_epsilon: f64 = 0.00390625;
        // check that the determinant is near +/-1
        const det: f64 = matrix.ax * matrix.dy - matrix.by * matrix.cx;
        if (@abs(det * det - 1.0) < scaling_epsilon) {
            // check that one axis is close to zero
            if (@abs(matrix.by) < scaling_epsilon and
                @abs(matrix.cx) < scaling_epsilon)
                break :_has_unity_scale true;
            if (@abs(matrix.ax) < scaling_epsilon and
                @abs(matrix.dy) < scaling_epsilon)
                break :_has_unity_scale true;
            // If rotations are allowed then it must instead test for
            // orthogonality. This is xx*xy+yx*yy ~= 0.
        }
        break :_has_unity_scale false;
    };

    if (has_unity_scale) return radius;

    i = a * a + b * b;
    j = c * c + d * d;

    f = 0.5 * (i + j);
    g = 0.5 * (i - j);
    h = a * c + b * d;

    return radius * @sqrt(f + math.hypot(g, h));

    //
    // we don't need the minor axis length, which is
    // double min = radius * sqrt (f - sqrt (g*g+h*h));
    //
}

// We want to draw a single spline approximating a circular arc radius
// R from angle A to angle B. Since we want a symmetric spline that
// matches the endpoints of the arc in position and slope, we know
// that the spline control points must be:
//
//      (R * cos(A), R * sin(A))
//      (R * cos(A) - h * sin(A), R * sin(A) + h * cos (A))
//      (R * cos(B) + h * sin(B), R * sin(B) - h * cos (B))
//      (R * cos(B), R * sin(B))
//
// for some value of h.
//
// "Approximation of circular arcs by cubic polynomials", Michael
// Goldapp, Computer Aided Geometric Design 8 (1991) 227-238, provides
// various values of h along with error analysis for each.
//
// From that paper, a very practical value of h is:
//
//      h = 4/3 * R * tan(angle/4)
//
// This value does not give the spline with minimal error, but it does
// provide a very good approximation, (6th-order convergence), and the
// error expression is quite simple, (see the comment for
// arc_error_normalized).

fn arc_segment(
    path_impl: *const PathVTable,
    xc: f64,
    yc: f64,
    radius: f64,
    angle_A: f64,
    angle_B: f64,
) PathVTable.Error!void {
    const r_sin_A = radius * @sin(angle_A);
    const r_cos_A = radius * @cos(angle_A);
    const r_sin_B = radius * @sin(angle_B);
    const r_cos_B = radius * @cos(angle_B);

    const h = 4.0 / 3.0 * @tan((angle_B - angle_A) / 4.0);

    try path_impl.curveTo(
        xc + r_cos_A - h * r_sin_A,
        yc + r_sin_A + h * r_cos_A,
        xc + r_cos_B + h * r_sin_B,
        yc + r_sin_B - h * r_cos_B,
        xc + r_cos_B,
        yc + r_sin_B,
    );
}

const Direction = enum {
    forward,
    reverse,
};

/// Checks for NaNs/Infs by squaring the number (will detect overflow in
/// addition to NaN/Inf propagation).
fn is_finite(x: f64) bool {
    return x * x >= 0.0;
}

pub fn arc_in_direction(
    path_impl: *const PathVTable,
    xc: f64,
    yc: f64,
    radius: f64,
    angle_min: f64,
    angle_max: f64,
    dir: Direction,
    ctm: Transformation,
    tolerance_: ?f64,
) PathVTable.Error!void {
    var amin = angle_min;
    var amax = angle_max;
    const tolerance = if (tolerance_) |t| t else options.default_tolerance;

    if (!is_finite(amax) or !is_finite(amin)) return;

    debug.assert(amax >= amin);

    if (amax - amin > 2 * math.pi * @as(f64, @floatFromInt(max_full_circles))) {
        amax = @mod(amax - amin, 2 * math.pi);
        amin = @mod(amin, 2 * math.pi);
        amax += amin + 2 * math.pi * @as(f64, @floatFromInt(max_full_circles));
    }

    // Recurse if drawing arc larger than pi
    if (amax - amin > math.pi) {
        const amid = amin + (amax - amin) / 2.0;
        if (dir == .forward) {
            try arc_in_direction(path_impl, xc, yc, radius, amin, amid, dir, ctm, tolerance);
            try arc_in_direction(path_impl, xc, yc, radius, amid, amax, dir, ctm, tolerance);
        } else {
            try arc_in_direction(path_impl, xc, yc, radius, amid, amax, dir, ctm, tolerance);
            try arc_in_direction(path_impl, xc, yc, radius, amin, amid, dir, ctm, tolerance);
        }
    } else if (amax != amin) {
        var segments = arc_segments_needed(amax - amin, radius, ctm, tolerance);
        var step = (amax - amin) / @as(f64, @floatFromInt(segments));
        segments -= 1;

        if (dir == .reverse) {
            const t = amin;
            amin = amax;
            amax = t;

            step = -step;
        }

        try path_impl.lineTo(
            xc + radius * @cos(amin),
            yc + radius * @sin(amin),
        );

        for (0..@max(0, segments)) |_| {
            try arc_segment(path_impl, xc, yc, radius, amin, amin + step);
            amin += step;
        }

        try arc_segment(path_impl, xc, yc, radius, amin, amax);
    } else {
        try path_impl.lineTo(xc + radius * @cos(amin), yc + radius * @sin(amin));
    }
}
