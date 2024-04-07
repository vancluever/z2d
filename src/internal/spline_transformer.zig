// The code in this file takes a lot of its logic from the Cairo project,
// namely src/cairo-spline.c.
//
// Cairo can be found at https://www.cairographics.org, governed by MPL 1.1 and
// LGPL 2.1, which can be found in the Cairo project's COPYING file. This
// project specifically uses this code under the terms of the MPL.
//
// TODO: There's a lot of matrix operations in this code; it would be neat to
// see how much of this could be implemented as vectors.

const std = @import("std");
const mem = @import("std").mem;

const polypkg = @import("polygon.zig");
const nodepkg = @import("nodes.zig");
const units = @import("../units.zig");

/// Given a set of four points representing a bezier curve ("spline"),
/// subdivide the curve into a series of line_to nodes.
///
/// The supplied tolerance is in pixels (fractions are supported). Higher
/// tolerance will give better performance, while a smaller tolerance will give
/// better quality.
///
/// The returned node list is owned by the caller and deinit should be
/// called on it.
pub fn transform(
    alloc: mem.Allocator,
    a: units.Point,
    b: units.Point,
    c: units.Point,
    d: units.Point,
    tolerance: f64,
) !std.ArrayList(nodepkg.PathNode) {
    var nodes = std.ArrayList(nodepkg.PathNode).init(alloc);
    errdefer nodes.deinit();

    // Both tangents being zero means that this is just a straight line.
    if (a.equal(b) and c.equal(d)) {
        try nodes.append(.{ .line_to = .{ .point = d } });
        return nodes;
    }

    // Our initial knot set
    var s1: Knots = .{ .a = a, .b = b, .c = c, .d = d };

    // Decompose the curve into its individual points, plotting them along
    // the way.
    try decomposeInto(&nodes, &s1, a, tolerance * tolerance);

    // Plot our last point in the curve before finishing
    try nodes.append(.{ .line_to = .{ .point = d } });

    return nodes;
}

/// Inner and recursive decomposition into the specified knot set.
fn decomposeInto(
    nodes: *std.ArrayList(nodepkg.PathNode),
    s1: *Knots,
    start: units.Point,
    tolerance: f64,
) !void {
    if (s1.errorSq() < tolerance) {
        // Add the point if we're not the actual initial point itself in the
        // larger curve (our implementations will always plot the initial
        // move_to or last line point, so this would be a redundant/degenerate
        // point, and it also throws out current stroke state machine in an
        // unreachable state).
        if (!s1.a.equal(start)) {
            try nodes.append(.{ .line_to = .{ .point = s1.a } });
        }

        // Return in all cases since we're done recursion.
        return;
    }

    // Split our spline
    var s2 = s1.deCasteljau();

    // Recurse into each half
    try decomposeInto(nodes, s1, start, tolerance);
    return try decomposeInto(nodes, &s2, start, tolerance);
}

/// Represents knots on a spline.
const Knots = struct {
    a: units.Point,
    b: units.Point,
    c: units.Point,
    d: units.Point,

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
        const ab: units.Point = lerpHalf(self.a, self.b);
        const bc: units.Point = lerpHalf(self.b, self.c);
        const cd: units.Point = lerpHalf(self.c, self.d);
        const abbc: units.Point = lerpHalf(ab, bc);
        const bccd: units.Point = lerpHalf(bc, cd);
        const final: units.Point = lerpHalf(abbc, bccd);

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

fn lerpHalf(a: units.Point, b: units.Point) units.Point {
    // The lerp is basically a + ((b - a) / 2), aka the middle of AB is half of
    // the difference between A and B.
    return .{
        .x = a.x + ((b.x - a.x) / 2),
        .y = a.y + ((b.y - a.y) / 2),
    };
}
