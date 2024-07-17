// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024 Chris Marchesi
//   Copyright © 2002 University of Southern California
//
// Portions of the code in this file have been derived and adapted from the
// Cairo project (https://www.cairographics.org/), notably cairo-arc.c.

const math = @import("std").math;
const debug = @import("std").debug;

const options = @import("../options.zig");

const PathVTable = @import("PathVTable.zig");

const max_full_circles: usize = 65536;

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

    var i: usize = 0;
    while (i < table.len) : (i += 1) {
        if (table[i].err < tolerance) return table[i].angle;
    }

    i += 1;

    var angle: f64 = undefined;
    while (true) {
        angle = math.pi / @as(f64, @floatFromInt(i));
        i += 1;
        const err = arc_error_normalized(angle);
        if (err > tolerance and i < max_segments) {
            break;
        }
    }

    return angle;
}

fn arc_segments_needed(angle: f64, radius: f64, tolerance: f64) usize {
    // TODO: Our arcs cannot do ellipses at this time due to the fact that we
    // have not implemented transformation matrices yet. After that's done,
    // this should be modified to transform the radius to the appropriate
    // length of the major axis.
    const max_angle = arc_max_angle_for_tolerance_normalized(tolerance / radius);

    return @intFromFloat(@ceil(@abs(angle) / max_angle));
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
) !void {
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
    tolerance_: ?f64,
) !void {
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
            try arc_in_direction(path_impl, xc, yc, radius, amin, amid, dir, tolerance);
            try arc_in_direction(path_impl, xc, yc, radius, amid, amax, dir, tolerance);
        } else {
            try arc_in_direction(path_impl, xc, yc, radius, amid, amax, dir, tolerance);
            try arc_in_direction(path_impl, xc, yc, radius, amin, amid, dir, tolerance);
        }
    } else if (amax != amin) {
        var segments = arc_segments_needed(amax - amin, radius, tolerance);
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

        var i: usize = 0;
        while (i < segments) : ({
            i += 1;
            amin += step;
        }) {
            try arc_segment(path_impl, xc, yc, radius, amin, amin + step);
        }

        try arc_segment(path_impl, xc, yc, radius, amin, amax);
    } else {
        try path_impl.lineTo(xc + radius * @cos(amin), yc + radius * @sin(amin));
    }
}
