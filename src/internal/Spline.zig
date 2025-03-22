// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024-2025 Chris Marchesi
//   Copyright © 2002 University of Southern California
//
// Portions of the code in this file have been derived and adapted from the
// Cairo project (https://www.cairographics.org/), notably cairo-spline.c.

//! Given a set of four points representing a bezier curve ("spline"),
//! subdivide the curve into a series of line_to nodes.
//!
//! The supplied tolerance is in pixels (fractions are supported). Higher
//! tolerance will give better performance, while a smaller tolerance will give
//! better quality.
const Spline = @This();

const std = @import("std");
const mem = @import("std").mem;

const nodepkg = @import("path_nodes.zig");
const Point = @import("Point.zig");
const PlotterVTable = @import("PlotterVTable.zig");

// Initial points.
a: Point,
b: Point,
c: Point,
d: Point,

// Error tolerance
tolerance: f64,

// Plotter implementation.
plotter_impl: *const PlotterVTable,

/// Run decomposition on the spline to break it down to its individual lines,
/// plotting each line along the way.
pub fn decompose(self: *Spline) PlotterVTable.Error!void {
    // Both tangents being zero means that this is just a straight line.
    if (self.a.equal(self.b) and self.c.equal(self.d)) {
        try self.plotter_impl.lineTo(.{ .point = self.d });
        return;
    }

    // Our initial knot set
    var s1: Knots = .{ .a = self.a, .b = self.b, .c = self.c, .d = self.d };

    // Decompose the curve into its individual points, plotting them along
    // the way.
    try self.decomposeInto(&s1, self.a, self.tolerance * self.tolerance);

    // Plot our last point in the curve before finishing
    try self.plotter_impl.lineTo(.{ .point = self.d });
}

/// Inner and recursive decomposition into the specified knot set.
fn decomposeInto(self: *Spline, s1: *Knots, start: Point, tolerance: f64) PlotterVTable.Error!void {
    if (s1.errorSq() < tolerance) {
        if (!s1.a.equal(start)) {
            try self.plotter_impl.lineTo(.{ .point = s1.a });
        }

        return;
    }

    // Split our spline
    var s2 = s1.deCasteljau();

    // Recurse into each half
    try self.decomposeInto(s1, start, tolerance);
    try self.decomposeInto(&s2, start, tolerance);
}

/// Represents knots on a spline.
const Knots = struct {
    a: Point,
    b: Point,
    c: Point,
    d: Point,

    /// Returns an upper bound on the error (squared) that could result from
    /// approximating the spline as a line segment connecting the two
    /// endpoints.
    fn errorSq(self: Knots) f64 {
        // Compute the distance between the control points (A -> B, A -> C). We
        // eventually select the larger of these two as our error.
        var b_x_delta = self.b.x - self.a.x;
        var b_y_delta = self.b.y - self.a.y;
        var c_x_delta = self.c.x - self.a.x;
        var c_y_delta = self.c.y - self.a.y;

        if (self.a.x != self.d.x or self.a.y != self.d.y) {
            const d_x_delta = self.d.x - self.a.x;
            const d_y_delta = self.d.y - self.a.y;
            const d_dot_sq = dotSq(f64, d_x_delta, d_y_delta);

            const b_d_dot = b_x_delta * d_x_delta + b_y_delta * d_y_delta;
            if (b_d_dot >= d_dot_sq) {
                b_x_delta -= d_x_delta;
                b_y_delta -= d_y_delta;
            } else {
                b_x_delta -= b_d_dot / d_dot_sq * d_x_delta;
                b_y_delta -= b_d_dot / d_dot_sq * d_y_delta;
            }

            const c_d_dot = c_x_delta * d_x_delta + c_y_delta * d_y_delta;
            if (c_d_dot >= d_dot_sq) {
                c_x_delta -= d_x_delta;
                c_y_delta -= d_y_delta;
            } else {
                c_x_delta -= c_d_dot / d_dot_sq * d_x_delta;
                c_y_delta -= c_d_dot / d_dot_sq * d_y_delta;
            }
        }

        const b_err = dotSq(f64, b_x_delta, b_y_delta);
        const c_err = dotSq(f64, c_x_delta, c_y_delta);

        if (b_err > c_err) {
            return b_err;
        } else {
            return c_err;
        }
    }

    /// Subdivides/linearly interpolates (lerps) the current knot using De
    /// Casteljau labeling. Sets the current knot to the first half (A ->
    /// middle of BC), and returns the second half (middle of BC -> D).
    fn deCasteljau(self: *Knots) Knots {
        const ab: Point = lerpHalf(self.a, self.b);
        const bc: Point = lerpHalf(self.b, self.c);
        const cd: Point = lerpHalf(self.c, self.d);
        const abbc: Point = lerpHalf(ab, bc);
        const bccd: Point = lerpHalf(bc, cd);
        const final: Point = lerpHalf(abbc, bccd);

        // Build the result first since we're swapping stuff in the original
        const result: Knots = .{
            .a = final,
            .b = bccd,
            .c = cd,
            .d = self.d,
        };

        // Update the original
        self.b = ab;
        self.c = abbc;
        self.d = final;

        // Done
        return result;
    }
};

fn dotSq(comptime T: type, x: T, y: T) T {
    return x * x + y * y;
}

fn lerpHalf(a: Point, b: Point) Point {
    // The lerp is basically a + ((b - a) / 2), aka the middle of AB is half of
    // the difference between A and B.
    return .{
        .x = a.x + ((b.x - a.x) / 2),
        .y = a.y + ((b.y - a.y) / 2),
    };
}
