// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024-2026 Chris Marchesi

//! Path offsetting.
//!
//! This is a very simple path offset based off of adjusting a path inward
//! (inset) or outward (outset) based on the direction of the polygon or path.
//!
//! Closed paths are expected to represent simple polygons (no
//! self-intersections). Open paths are allowed but are expected to not change
//! direction.
//!
//! Paths that do not conform to these constraints may produce undesirable
//! results.

const std = @import("std");

const nodepkg = @import("../path_nodes.zig");
const shared = @import("shared.zig");

const InputSet = @import("InputSet.zig");
const OutputSet = @import("OutputSet.zig");
const Point = @import("../Point.zig");
const Slope = @import("../tess/Slope.zig");
const Face = @import("../tess/Face.zig");
const Transformation = @import("../../Transformation.zig");

pub const Error = InputSet.FromNodesError || OutputSet.ToNodesError || std.mem.Allocator.Error;

/// Caller owns the memory.
pub fn run(
    alloc: std.mem.Allocator,
    in: []const nodepkg.PathNode,
    tolerance: f64,
    offset: f64,
) Error![]nodepkg.PathNode {
    var input_set = try InputSet.fromNodes(alloc, in, tolerance);
    defer input_set.deinit(alloc);
    var output_set: OutputSet = .empty;
    defer output_set.deinit(alloc);
    if (offset == 0) {
        // no-op all nodes if zero offset was supplied
        for (input_set.contours.items) |*contour| {
            try shared.noopContour(alloc, &output_set, contour);
        }
    } else {
        for (input_set.contours.items) |*contour| {
            if (contour.closed) {
                contour.alignSegments();
                try runClosed(alloc, &output_set, contour, offset);
            } else {
                try runOpen(alloc, &output_set, contour, offset);
            }
        }
    }

    return try output_set.toNodes(alloc);
}

/// Asserts that the input contour is closed and has at least 3 nodes.
fn runClosed(
    alloc: std.mem.Allocator,
    out: *OutputSet,
    in: *const InputSet.Contour,
    offset: f64,
) std.mem.Allocator.Error!void {
    std.debug.assert(in.closed);
    std.debug.assert(in.segments.items.len >= 3);

    var result: OutputSet.Contour = .empty;
    errdefer result.deinit(alloc);
    const clockwise = in.segments.items[0].orientation == .cw;

    // Initial point
    {
        const in_seg = in.segments.items[in.segments.items.len - 1];
        const out_seg = in.segments.items[0];
        try result.plot(alloc, intersect(in_seg, out_seg, offset, clockwise));
    }

    // Everything else
    for (in.segments.items[1..], 0..) |out_seg, in_idx| {
        const in_seg = in.segments.items[in_idx];
        try result.plot(alloc, intersect(in_seg, out_seg, offset, clockwise));
    }

    result.close();
    try out.contours.append(alloc, result);
}

/// Asserts that the input contour has at least 2 nodes.
fn runOpen(
    alloc: std.mem.Allocator,
    out: *OutputSet,
    in: *const InputSet.Contour,
    offset: f64,
) std.mem.Allocator.Error!void {
    var result: OutputSet.Contour = .empty;
    errdefer result.deinit(alloc);
    const clockwise = switch (in.segments.items[0].orientation) {
        .cw => true,
        .ccw => false,
        else => {
            // Invalid means that there was only one element, always assume
            // clockwise and return.
            std.debug.assert(in.segments.items.len == 1);
            try result.plot(alloc, offsetSingle(
                in.segments.items[0].p0,
                in.segments.items[0].slope,
                offset,
                true,
            ));
            try result.plot(alloc, offsetSingle(
                in.segments.items[0].p1,
                in.segments.items[0].slope,
                offset,
                true,
            ));
            try out.contours.append(alloc, result);
            return;
        },
    };

    try result.plot(alloc, offsetSingle(
        in.segments.items[0].p0,
        in.segments.items[0].slope,
        offset,
        clockwise,
    ));
    for (in.segments.items[1..], 0..) |out_seg, in_idx| {
        const in_seg = in.segments.items[in_idx];
        try result.plot(alloc, intersect(in_seg, out_seg, offset, clockwise));
    }
    try result.plot(alloc, offsetSingle(
        in.segments.items[in.segments.items.len - 1].p1,
        in.segments.items[in.segments.items.len - 1].slope,
        offset,
        clockwise,
    ));

    try out.contours.append(alloc, result);
}

/// Perform a projected line-line intersection off of the inner points of the
/// two consecutive segments, based on the supplied offset and direction.
fn intersect(in: InputSet.Contour.Segment, out: InputSet.Contour.Segment, offset: f64, clockwise: bool) Point {
    // We use a parametric derivation to calculate our intersections (note that
    // this is how it's done also in InputSet and Face, but I want to provide a
    // better explanation for both myself and anyone else looking at the code.
    //
    // In the form that we need it in here, our intersecting lines are
    // represented by: 1) a point, and 2) a vector (our normalized slope). This
    // is similar to the parametric intersections calculated in InputSet, but
    // here, we do not place restrictions on our parametric projections (i.e.,
    // we assume the lines extend infinitely), so we can simplify things below
    // to the following two equations:
    //
    //   i = p1 + t * v1
    //   i = p2 + u * v2
    //
    //   or:
    //
    //   p1 + t * v1 = p2 + u * v2
    //
    // Rearranged:
    //
    //   t * v1 - u * v2 = p2 - p1
    //
    // This can now be expressed as two equations for each of the x and
    // y-coordinates (sub in our normalized dx and dy for our vectors):
    //
    //   t * dx1 - u * dx2 = x2 - x1
    //   t * dy1 - u * dy2 = y2 - y1
    //
    // This can now be solved under Cramer's Rule, as it can be expressed as:
    //
    // [ dx1 dx2 ] [  t ] [ x2 - x1 ]
    // [ dy1 dy2 ] [ -u ] [ y2 - y1 ]
    //
    // Solving for t:
    //
    //  | (x2 - x1) dx2 |
    //  | (y2 - y1) dy2 |
    // -------------------
    //     | dx1 dx2 |
    //     | dy1 dy2 |
    //
    // Equals:
    //
    //  (x2 - x1) * dy2 - (y2 - y1) * dx2
    // -----------------------------------
    //        dx1 * dy2 - dy1 * dx2
    //
    // Now that we know t, and do not place any restrictions on it, we can
    // compute the intersection easily by plugging it into our inbound equation:
    //
    // x = x1 + t * dx1
    // y = y1 + t * dy1
    //
    // Since the points are the same, and since we're projecting infinitely, we
    // don't need to worry about solving for u (or -u, in this instance).

    // Shortened slopes so that our equations are more sane
    const dx1 = in.slope.dx;
    const dy1 = in.slope.dy;
    const dx2 = out.slope.dx;
    const dy2 = out.slope.dy;

    // Offset adjustment for points
    const xoff1 = -dy1 * offset;
    const yoff1 = dx1 * offset;
    const xoff2 = -dy2 * offset;
    const yoff2 = dx2 * offset;

    // Adjusted inner points
    const x1, const y1, const x2, const y2 = if (clockwise)
        .{ in.p1.x - xoff1, in.p1.y - yoff1, out.p0.x - xoff2, out.p0.y - yoff2 }
    else
        .{ in.p1.x + xoff1, in.p1.y + yoff1, out.p0.x + xoff2, out.p0.y + yoff2 };

    // Get our divisor and assert (note: we should be far past the point of
    // ensuring that this is non-zero)
    const div = dx1 * dy2 - dy1 * dx2;
    std.debug.assert(div != 0);

    // Solve for t
    const t = ((x2 - x1) * dy2 - (y2 - y1) * dx2) / div;

    // Done
    return .{
        .x = x1 + t * dx1,
        .y = y1 + t * dy1,
    };
}

// used for start and end points on open contour.
fn offsetSingle(point: Point, slope: InputSet.Contour.Segment.Slope, offset: f64, clockwise: bool) Point {
    const dx1 = slope.dx;
    const dy1 = slope.dy;
    const xoff1 = -dy1 * offset;
    const yoff1 = dx1 * offset;
    return if (clockwise)
        .{ .x = point.x - xoff1, .y = point.y - yoff1 }
    else
        .{ .x = point.x + xoff1, .y = point.y + yoff1 };
}

test "offset, e2e" {
    const alloc = std.testing.allocator;
    const in = [_]nodepkg.PathNode{
        // Star
        .{ .move_to = .{ .point = .{ .x = 15, .y = 13 } } },
        .{ .line_to = .{ .point = .{ .x = 22.2, .y = 13 } } },
        .{ .line_to = .{ .point = .{ .x = 25, .y = 5 } } },
        .{ .line_to = .{ .point = .{ .x = 27.8, .y = 13 } } },
        .{ .line_to = .{ .point = .{ .x = 35, .y = 13 } } },
        .{ .line_to = .{ .point = .{ .x = 29.22641509433962, .y = 17.07547169811321 } } },
        .{ .line_to = .{ .point = .{ .x = 32, .y = 25 } } },
        .{ .line_to = .{ .point = .{ .x = 25, .y = 20.058823529411764 } } },
        .{ .line_to = .{ .point = .{ .x = 18, .y = 25 } } },
        .{ .line_to = .{ .point = .{ .x = 20.77358490566038, .y = 17.075471698113205 } } },
        .{ .close_path = .{} },
        .{ .move_to = .{ .point = .{ .x = 15, .y = 13 } } },
        // Triangle (counter-clockwise, testing point re-alignment to leftmost)
        .{ .move_to = .{ .point = .{ .x = 110, .y = 110 } } },
        .{ .line_to = .{ .point = .{ .x = 60, .y = 10 } } },
        .{ .line_to = .{ .point = .{ .x = 10, .y = 110 } } },
        .{ .close_path = .{} },
        .{ .move_to = .{ .point = .{ .x = 110, .y = 110 } } },
        // Fake curve #1 (open, clockwise)
        .{ .move_to = .{ .point = .{ .x = 130, .y = 20 } } },
        .{ .line_to = .{ .point = .{ .x = 149, .y = 30 } } },
        .{ .line_to = .{ .point = .{ .x = 160, .y = 50 } } },
        .{ .line_to = .{ .point = .{ .x = 160, .y = 70 } } },
        .{ .line_to = .{ .point = .{ .x = 150, .y = 90 } } },
        .{ .line_to = .{ .point = .{ .x = 130, .y = 100 } } },
        // Fake curve #2 (open, counter-clockwise)
        .{ .move_to = .{ .point = .{ .x = 100, .y = 160 } } },
        .{ .line_to = .{ .point = .{ .x = 90, .y = 150 } } },
        .{ .line_to = .{ .point = .{ .x = 70, .y = 140 } } },
        .{ .line_to = .{ .point = .{ .x = 50, .y = 140 } } },
        .{ .line_to = .{ .point = .{ .x = 30, .y = 150 } } },
        .{ .line_to = .{ .point = .{ .x = 21, .y = 160 } } },
        // Single line
        .{ .move_to = .{ .point = .{ .x = 10, .y = 300 } } },
        .{ .line_to = .{ .point = .{ .x = 110, .y = 400 } } },
    };

    {
        // Inset
        const expected = [_]nodepkg.PathNode{
            // Star
            .{ .move_to = .{ .point = .{ .x = 21.301442007780807, .y = 15 } } },
            .{ .line_to = .{ .point = .{ .x = 23.61896201004171, .y = 15 } } },
            .{ .line_to = .{ .point = .{ .x = 25, .y = 11.054177171547744 } } },
            .{ .line_to = .{ .point = .{ .x = 26.38103798995829, .y = 15 } } },
            .{ .line_to = .{ .point = .{ .x = 28.698557992219197, .y = 15 } } },
            .{ .line_to = .{ .point = .{ .x = 26.84016931116092, .y = 16.311803774864668 } } },
            .{ .line_to = .{ .point = .{ .x = 28.047780421610277, .y = 19.762121233291396 } } },
            .{ .line_to = .{ .point = .{ .x = 25, .y = 17.610746818037082 } } },
            .{ .line_to = .{ .point = .{ .x = 21.952219578389723, .y = 19.762121233291396 } } },
            .{ .line_to = .{ .point = .{ .x = 23.15983068883908, .y = 16.31180377486466 } } },
            .{ .close_path = .{} },
            .{ .move_to = .{ .point = .{ .x = 21.301442007780807, .y = 15 } } },
            // Triangle
            .{ .move_to = .{ .point = .{ .x = 13.236067977499792, .y = 108 } } },
            .{ .line_to = .{ .point = .{ .x = 106.76393202250021, .y = 108 } } },
            .{ .line_to = .{ .point = .{ .x = 60, .y = 14.472135954999583 } } },
            .{ .close_path = .{} },
            .{ .move_to = .{ .point = .{ .x = 13.236067977499792, .y = 108 } } },
            // Fake curve #1
            .{ .move_to = .{ .point = .{ .x = 129.06850713433477, .y = 21.769836444763964 } } },
            .{ .line_to = .{ .point = .{ .x = 147.53701445992533, .y = 31.490103458232674 } } },
            .{ .line_to = .{ .point = .{ .x = 158, .y = 50.51371353109574 } } },
            .{ .line_to = .{ .point = .{ .x = 158, .y = 69.5278640450004 } } },
            .{ .line_to = .{ .point = .{ .x = 148.50928801500012, .y = 88.50928801500015 } } },
            .{ .line_to = .{ .point = .{ .x = 129.10557280900008, .y = 98.21114561800017 } } },
            // Fake curve #2
            .{ .move_to = .{ .point = .{ .x = 98.58578643762691, .y = 161.4142135623731 } } },
            .{ .line_to = .{ .point = .{ .x = 88.8152817055072, .y = 151.64370883025342 } } },
            .{ .line_to = .{ .point = .{ .x = 69.5278640450004, .y = 142 } } },
            .{ .line_to = .{ .point = .{ .x = 50.472135954999594, .y = 142 } } },
            .{ .line_to = .{ .point = .{ .x = 31.233206599390776, .y = 151.61946467780442 } } },
            .{ .line_to = .{ .point = .{ .x = 22.486588292494332, .y = 161.3379294632449 } } },
            // Single line
            .{ .move_to = .{ .point = .{ .x = 8.585786437626904, .y = 301.4142135623731 } } },
            .{ .line_to = .{ .point = .{ .x = 108.58578643762691, .y = 401.4142135623731 } } },
        };

        const out = try run(alloc, &in, 0.1, -2);
        defer alloc.free(out);
        try std.testing.expectEqualDeep(&expected, out);
    }

    {
        // Outset
        const expected = [_]nodepkg.PathNode{
            // Star
            .{ .move_to = .{ .point = .{ .x = 8.698557992219195, .y = 11 } } },
            .{ .line_to = .{ .point = .{ .x = 20.78103798995829, .y = 11 } } },
            .{ .line_to = .{ .point = .{ .x = 25, .y = -1.0541771715477442 } } },
            .{ .line_to = .{ .point = .{ .x = 29.21896201004171, .y = 11 } } },
            .{ .line_to = .{ .point = .{ .x = 41.3014420077808, .y = 11 } } },
            .{ .line_to = .{ .point = .{ .x = 31.612660877518323, .y = 17.83913962136175 } } },
            .{ .line_to = .{ .point = .{ .x = 35.95221957838972, .y = 30.237878766708604 } } },
            .{ .line_to = .{ .point = .{ .x = 25, .y = 22.506900240786447 } } },
            .{ .line_to = .{ .point = .{ .x = 14.047780421610279, .y = 30.237878766708604 } } },
            .{ .line_to = .{ .point = .{ .x = 18.387339122481677, .y = 17.839139621361745 } } },
            .{ .close_path = .{} },
            .{ .move_to = .{ .point = .{ .x = 8.698557992219195, .y = 11 } } },
            // Triangle
            .{ .move_to = .{ .point = .{ .x = 6.763932022500208, .y = 112 } } },
            .{ .line_to = .{ .point = .{ .x = 113.23606797749979, .y = 112 } } },
            .{ .line_to = .{ .point = .{ .x = 60, .y = 5.527864045000417 } } },
            .{ .close_path = .{} },
            .{ .move_to = .{ .point = .{ .x = 6.763932022500208, .y = 112 } } },
            // Fake curve #1
            .{ .move_to = .{ .point = .{ .x = 130.93149286566523, .y = 18.230163555236036 } } },
            .{ .line_to = .{ .point = .{ .x = 150.46298554007467, .y = 28.509896541767326 } } },
            .{ .line_to = .{ .point = .{ .x = 162, .y = 49.48628646890426 } } },
            .{ .line_to = .{ .point = .{ .x = 162, .y = 70.4721359549996 } } },
            .{ .line_to = .{ .point = .{ .x = 151.49071198499988, .y = 91.49071198499985 } } },
            .{ .line_to = .{ .point = .{ .x = 130.89442719099992, .y = 101.78885438199983 } } },
            // Fake curve #2
            .{ .move_to = .{ .point = .{ .x = 101.41421356237309, .y = 158.5857864376269 } } },
            .{ .line_to = .{ .point = .{ .x = 91.1847182944928, .y = 148.35629116974658 } } },
            .{ .line_to = .{ .point = .{ .x = 70.4721359549996, .y = 138 } } },
            .{ .line_to = .{ .point = .{ .x = 49.527864045000406, .y = 138 } } },
            .{ .line_to = .{ .point = .{ .x = 28.766793400609224, .y = 148.38053532219558 } } },
            .{ .line_to = .{ .point = .{ .x = 19.513411707505668, .y = 158.6620705367551 } } },
            // Single line
            .{ .move_to = .{ .point = .{ .x = 11.414213562373096, .y = 298.5857864376269 } } },
            .{ .line_to = .{ .point = .{ .x = 111.41421356237309, .y = 398.5857864376269 } } },
        };

        const out = try run(alloc, &in, 0.1, 2);
        defer alloc.free(out);
        try std.testing.expectEqualDeep(&expected, out);
    }
}

test "offset, zero value" {
    const alloc = std.testing.allocator;
    const in = [_]nodepkg.PathNode{
        // Star
        .{ .move_to = .{ .point = .{ .x = 15, .y = 13 } } },
        .{ .line_to = .{ .point = .{ .x = 22.2, .y = 13 } } },
        .{ .line_to = .{ .point = .{ .x = 25, .y = 5 } } },
        .{ .line_to = .{ .point = .{ .x = 27.8, .y = 13 } } },
        .{ .line_to = .{ .point = .{ .x = 35, .y = 13 } } },
        .{ .line_to = .{ .point = .{ .x = 29.22641509433962, .y = 17.07547169811321 } } },
        .{ .line_to = .{ .point = .{ .x = 32, .y = 25 } } },
        .{ .line_to = .{ .point = .{ .x = 25, .y = 20.058823529411764 } } },
        .{ .line_to = .{ .point = .{ .x = 18, .y = 25 } } },
        .{ .line_to = .{ .point = .{ .x = 20.77358490566038, .y = 17.075471698113205 } } },
        .{ .close_path = .{} },
        .{ .move_to = .{ .point = .{ .x = 15, .y = 13 } } },
        // Triangle (counter-clockwise, testing point re-alignment to leftmost)
        .{ .move_to = .{ .point = .{ .x = 110, .y = 110 } } },
        .{ .line_to = .{ .point = .{ .x = 60, .y = 10 } } },
        .{ .line_to = .{ .point = .{ .x = 10, .y = 110 } } },
        .{ .close_path = .{} },
        .{ .move_to = .{ .point = .{ .x = 110, .y = 110 } } },
        // Fake curve #1 (open, clockwise)
        .{ .move_to = .{ .point = .{ .x = 130, .y = 20 } } },
        .{ .line_to = .{ .point = .{ .x = 149, .y = 30 } } },
        .{ .line_to = .{ .point = .{ .x = 160, .y = 50 } } },
        .{ .line_to = .{ .point = .{ .x = 160, .y = 70 } } },
        .{ .line_to = .{ .point = .{ .x = 150, .y = 90 } } },
        .{ .line_to = .{ .point = .{ .x = 130, .y = 100 } } },
        // Fake curve #2 (open, counter-clockwise)
        .{ .move_to = .{ .point = .{ .x = 100, .y = 160 } } },
        .{ .line_to = .{ .point = .{ .x = 90, .y = 150 } } },
        .{ .line_to = .{ .point = .{ .x = 70, .y = 140 } } },
        .{ .line_to = .{ .point = .{ .x = 50, .y = 140 } } },
        .{ .line_to = .{ .point = .{ .x = 30, .y = 150 } } },
        .{ .line_to = .{ .point = .{ .x = 21, .y = 160 } } },
        // Single line
        .{ .move_to = .{ .point = .{ .x = 10, .y = 300 } } },
        .{ .line_to = .{ .point = .{ .x = 110, .y = 400 } } },
    };

    const out = try run(alloc, &in, 0.1, 0);
    defer alloc.free(out);
    try std.testing.expectEqualDeep(&in, out);
}
