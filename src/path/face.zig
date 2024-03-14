/// A Face represents a hypothetically-computed polygon edge for a stroked
/// line.
///
/// The face is computed from p0 -> p1 (see init). Interactions, such as
/// intersections, are specifically dictated by the orientation of any two
/// faces in relation to each other, when the faces are treated as segments
/// along the path, traveling in the same direction (e.g., p0 -> p1, p1 -> p2).
///
/// For each face, its stroked endpoints, denoted by cw (clockwise) and ccw
/// (counter-clockwise) are taken by rotating a point 90 degrees in that
/// direction along the line, starting from p0 (or p1), to half of the line
/// thickness, in the same direction of the line (e.g., p0 -> p1).
const Face = @This();

const math = @import("std").math;

const units = @import("../units.zig");

const FaceType = enum {
    horizontal,
    vertical,
    diagonal,
};

type: FaceType,
p0: units.Point,
p1: units.Point,
slope: units.Slope,
offset_x: f64,
offset_y: f64,
p0_cw: units.Point,
p0_ccw: units.Point,
p1_cw: units.Point,
p1_ccw: units.Point,

/// Computes a Face from two points in the direction of p0 -> p1.
pub fn init(p0: units.Point, p1: units.Point, thickness: f64) Face {
    const slope = units.Slope.init(p0, p1);
    const width = thickness / 2;
    if (slope.dy == 0) {
        return .{
            .type = .horizontal,
            .p0 = p0,
            .p1 = p1,
            .slope = slope,
            .offset_x = 0,
            .offset_y = width,
            .p0_cw = .{ .x = p0.x, .y = p0.y + math.copysign(width, slope.dx) },
            .p0_ccw = .{ .x = p0.x, .y = p0.y - math.copysign(width, slope.dx) },
            .p1_cw = .{ .x = p1.x, .y = p1.y + math.copysign(width, slope.dx) },
            .p1_ccw = .{ .x = p1.x, .y = p1.y - math.copysign(width, slope.dx) },
        };
    }
    if (slope.dx == 0) {
        return .{
            .type = .vertical,
            .p0 = p0,
            .p1 = p1,
            .slope = slope,
            .offset_x = width,
            .offset_y = 0,
            .p0_cw = .{ .x = p0.x - math.copysign(width, slope.dy), .y = p0.y },
            .p0_ccw = .{ .x = p0.x + math.copysign(width, slope.dy), .y = p0.y },
            .p1_cw = .{ .x = p1.x - math.copysign(width, slope.dy), .y = p1.y },
            .p1_ccw = .{ .x = p1.x + math.copysign(width, slope.dy), .y = p1.y },
        };
    }

    const theta = math.atan2(slope.dy, slope.dx);
    const offset_x = thickness / 2 * @sin(theta);
    const offset_y = thickness / 2 * @cos(theta);
    return .{
        .type = .diagonal,
        .p0 = p0,
        .p1 = p1,
        .slope = slope,
        .offset_x = offset_x,
        .offset_y = offset_y,
        .p0_cw = .{ .x = p0.x - offset_x, .y = p0.y + offset_y },
        .p0_ccw = .{ .x = p0.x + offset_x, .y = p0.y - offset_y },
        .p1_cw = .{ .x = p1.x - offset_x, .y = p1.y + offset_y },
        .p1_ccw = .{ .x = p1.x + offset_x, .y = p1.y - offset_y },
    };
}

pub fn intersectOuter(in: Face, out: Face) units.Point {
    return switch (in.type) {
        .horizontal => intersectHorizontal(in, out, true),
        .vertical => intersectVertical(in, out, true),
        .diagonal => intersectDiagonal(in, out, true),
    };
}

pub fn intersectInner(in: Face, out: Face) units.Point {
    return switch (in.type) {
        .horizontal => intersectHorizontal(in, out, false),
        .vertical => intersectVertical(in, out, false),
        .diagonal => intersectDiagonal(in, out, false),
    };
}

fn intersectHorizontal(in: Face, out: Face, outer: bool) units.Point {
    const points: struct {
        in_p1: units.Point,
        out_p1: units.Point,
        in_p0: units.Point,
    } = if (outer) .{
        .in_p1 = in.p1_ccw,
        .out_p1 = out.p1_ccw,
        .in_p0 = in.p0_ccw,
    } else .{
        .in_p1 = in.p1_cw,
        .out_p1 = out.p1_cw,
        .in_p0 = in.p0_cw,
    };

    switch (out.type) {
        .horizontal => {
            // We can just return our end-point outer
            return points.in_p1;
        },
        .vertical => {
            // Take the x/y intersection of our outer points.
            return .{
                .x = points.out_p1.x,
                .y = points.in_p0.y,
            };
        },
        .diagonal => {
            // Take the x-intercept with the origin being the horizontal
            // line outer point.
            return .{
                .x = points.out_p1.x - ((points.out_p1.y - points.in_p0.y) / out.slope.calculate()),
                .y = points.in_p0.y,
            };
        },
    }
}

fn intersectVertical(in: Face, out: Face, outer: bool) units.Point {
    const points: struct {
        in_p0: units.Point,
        out_p1: units.Point,
        in_p1: units.Point,
    } = if (outer) .{
        .in_p0 = in.p0_ccw,
        .out_p1 = out.p1_ccw,
        .in_p1 = in.p1_ccw,
    } else .{
        .in_p0 = in.p0_cw,
        .out_p1 = out.p1_cw,
        .in_p1 = in.p1_cw,
    };

    switch (out.type) {
        .horizontal => {
            // Take the x/y intersection of our outer points.
            return .{
                .x = points.in_p0.x,
                .y = points.out_p1.y,
            };
        },
        .vertical => {
            // We can just return our end-point outer
            return points.in_p1;
        },
        .diagonal => {
            // Take the y-intercept with the origin being the vertical
            // line outer point.
            return .{
                .x = points.in_p0.x,
                .y = points.out_p1.y - (out.slope.calculate() * (points.out_p1.x - points.in_p0.x)),
            };
        },
    }
}

fn intersectDiagonal(in: Face, out: Face, outer: bool) units.Point {
    const points: struct {
        in_p0: units.Point,
        out_p1: units.Point,
        in_p1: units.Point,
    } = if (outer) .{
        .in_p0 = in.p0_ccw,
        .out_p1 = out.p1_ccw,
        .in_p1 = in.p1_ccw,
    } else .{
        .in_p0 = in.p0_cw,
        .out_p1 = out.p1_cw,
        .in_p1 = in.p1_cw,
    };

    switch (out.type) {
        .horizontal => {
            // Take the x-intercept with the origin being the horizontal
            // line outer point.
            return .{
                .x = points.in_p0.x + ((points.out_p1.y - points.in_p0.y) / in.slope.calculate()),
                .y = points.out_p1.y,
            };
        },
        .vertical => {
            // Take the y-intercept with the origin being the vertical
            // line outer point.
            return .{
                .x = points.out_p1.x,
                .y = points.in_p0.y + (in.slope.calculate() * (points.out_p1.x - points.in_p0.x)),
            };
        },
        .diagonal => {
            return intersect(points.in_p0, points.out_p1, in.slope.calculate(), out.slope.calculate());
        },
    }
}

fn intersect(p0: units.Point, p1: units.Point, m0: f64, m1: f64) units.Point {
    // We do line-line intersection, based on the following equation:
    //
    // self.dy/self.dx + self.p0.y == other.dy/other.dx + other.p0.y
    //
    // This is line-line intercept when both y positions are normalized at
    // their y-intercepts (e.g. x=0).
    //
    // We take p0 at self as our reference origin, so normalize our other
    // point based on the difference between the two points in x-position.
    //
    // Source: Line-line intersection, Wikipedia contributors:
    // https://en.wikipedia.org/w/index.php?title=Line%E2%80%93line_intersection&oldid=1198068392.
    // See link for further details.
    const other_y_intercept = p1.y - (m1 * (p1.x - p0.x));

    // We can now compute our intersections. Note that we have to add the x of
    // p0 as an offset, as we have assumed this is the origin.
    const intersect_x = (other_y_intercept - p0.y) / (m0 - m1) + p0.x;
    const intersect_y = m0 * ((other_y_intercept - p0.y) / (m0 - m1)) + p0.y;
    return .{
        .x = intersect_x,
        .y = intersect_y,
    };
}
