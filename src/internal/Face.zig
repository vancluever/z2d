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

const std = @import("std");
const math = @import("std").math;
const mem = @import("std").mem;

const options = @import("../options.zig");

const Pen = @import("Pen.zig");
const Point = @import("../Point.zig");
const Slope = @import("Slope.zig");

const FaceType = enum {
    horizontal,
    vertical,
    diagonal,
};

type: FaceType,
p0: Point,
p1: Point,
width: f64,
slope: Slope,
offset_x: f64,
offset_y: f64,
p0_cw: Point,
p0_ccw: Point,
p1_cw: Point,
p1_ccw: Point,

/// Computes a Face from two points in the direction of p0 -> p1.
pub fn init(p0: Point, p1: Point, thickness: f64) Face {
    const slope = Slope.init(p0, p1);
    const half_width = thickness / 2;
    if (slope.dy == 0) {
        return .{
            .type = .horizontal,
            .p0 = p0,
            .p1 = p1,
            .width = thickness,
            .slope = slope,
            .offset_x = 0,
            .offset_y = math.copysign(half_width, slope.dx),
            .p0_cw = .{ .x = p0.x, .y = p0.y + math.copysign(half_width, slope.dx) },
            .p0_ccw = .{ .x = p0.x, .y = p0.y - math.copysign(half_width, slope.dx) },
            .p1_cw = .{ .x = p1.x, .y = p1.y + math.copysign(half_width, slope.dx) },
            .p1_ccw = .{ .x = p1.x, .y = p1.y - math.copysign(half_width, slope.dx) },
        };
    }
    if (slope.dx == 0) {
        return .{
            .type = .vertical,
            .p0 = p0,
            .p1 = p1,
            .width = thickness,
            .slope = slope,
            .offset_x = math.copysign(half_width, slope.dy),
            .offset_y = 0,
            .p0_cw = .{ .x = p0.x - math.copysign(half_width, slope.dy), .y = p0.y },
            .p0_ccw = .{ .x = p0.x + math.copysign(half_width, slope.dy), .y = p0.y },
            .p1_cw = .{ .x = p1.x - math.copysign(half_width, slope.dy), .y = p1.y },
            .p1_ccw = .{ .x = p1.x + math.copysign(half_width, slope.dy), .y = p1.y },
        };
    }

    const theta = math.atan2(slope.dy, slope.dx);
    const offset_x = half_width * @sin(theta);
    const offset_y = half_width * @cos(theta);
    return .{
        .type = .diagonal,
        .p0 = p0,
        .p1 = p1,
        .width = thickness,
        .slope = slope,
        .offset_x = offset_x,
        .offset_y = offset_y,
        .p0_cw = .{ .x = p0.x - offset_x, .y = p0.y + offset_y },
        .p0_ccw = .{ .x = p0.x + offset_x, .y = p0.y - offset_y },
        .p1_cw = .{ .x = p1.x - offset_x, .y = p1.y + offset_y },
        .p1_ccw = .{ .x = p1.x + offset_x, .y = p1.y - offset_y },
    };
}

pub fn intersectOuter(in: Face, out: Face) Point {
    return switch (in.type) {
        .horizontal => intersectHorizontal(in, out, true),
        .vertical => intersectVertical(in, out, true),
        .diagonal => intersectDiagonal(in, out, true),
    };
}

pub fn intersectInner(in: Face, out: Face) Point {
    return switch (in.type) {
        .horizontal => intersectHorizontal(in, out, false),
        .vertical => intersectVertical(in, out, false),
        .diagonal => intersectDiagonal(in, out, false),
    };
}

fn intersectHorizontal(in: Face, out: Face, outer: bool) Point {
    const points: struct {
        in_p1: Point,
        out_p1: Point,
        in_p0: Point,
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

fn intersectVertical(in: Face, out: Face, outer: bool) Point {
    const points: struct {
        in_p0: Point,
        out_p1: Point,
        in_p1: Point,
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

fn intersectDiagonal(in: Face, out: Face, outer: bool) Point {
    const points: struct {
        in_p0: Point,
        out_p1: Point,
        in_p1: Point,
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

fn intersect(p0: Point, p1: Point, m0: f64, m1: f64) Point {
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

pub fn cap_p0(
    self: Face,
    alloc: mem.Allocator,
    cap_mode: options.CapMode,
    clockwise: bool,
    tolerance: f64,
) !std.ArrayList(Point) {
    const reversed = init(self.p1, self.p0, self.width);
    return reversed.cap(
        alloc,
        cap_mode,
        clockwise,
        tolerance,
    );
}

pub fn cap_p1(
    self: Face,
    alloc: mem.Allocator,
    cap_mode: options.CapMode,
    clockwise: bool,
    tolerance: f64,
) !std.ArrayList(Point) {
    return self.cap(
        alloc,
        cap_mode,
        clockwise,
        tolerance,
    );
}

fn cap(
    self: Face,
    alloc: mem.Allocator,
    cap_mode: options.CapMode,
    clockwise: bool,
    tolerance: f64,
) !std.ArrayList(Point) {
    var result = std.ArrayList(Point).init(alloc);
    errdefer result.deinit();

    switch (cap_mode) {
        .butt => {
            try self.capButt(&result, clockwise);
        },
        .square => {
            try self.capSquare(&result, clockwise);
        },
        .round => {
            try self.capRound(alloc, &result, clockwise, tolerance);
        },
    }

    return result;
}

fn capButt(
    self: Face,
    result: *std.ArrayList(Point),
    clockwise: bool,
) !void {
    if (clockwise) {
        try result.append(self.p1_ccw);
        try result.append(self.p1_cw);
    } else {
        try result.append(self.p1_cw);
        try result.append(self.p1_ccw);
    }
}

fn capSquare(
    self: Face,
    result: *std.ArrayList(Point),
    clockwise: bool,
) !void {
    if (clockwise) {
        try result.append(self.p1_ccw);
        try result.append(.{
            .x = self.p1_ccw.x + self.offset_y,
            .y = self.p1_ccw.y + self.offset_x,
        });
        try result.append(.{
            .x = self.p1_cw.x + self.offset_y,
            .y = self.p1_cw.y + self.offset_x,
        });
        try result.append(self.p1_cw);
    } else {
        try result.append(self.p1_cw);
        try result.append(.{
            .x = self.p1_cw.x + self.offset_y,
            .y = self.p1_cw.y + self.offset_x,
        });
        try result.append(.{
            .x = self.p1_ccw.x + self.offset_y,
            .y = self.p1_ccw.y + self.offset_x,
        });
        try result.append(self.p1_ccw);
    }
}

fn capRound(
    self: Face,
    alloc: mem.Allocator,
    result: *std.ArrayList(Point),
    clockwise: bool,
    tolerance: f64,
) !void {
    var pen = try Pen.init(alloc, self.width, tolerance);
    defer pen.deinit();

    // We need to calculate our fan along the end as if we were
    // dealing with a 180 degree joint. So, treat it as if there
    // were two lines going in exactly opposite directions, i.e., flip the
    // incoming slope for the outgoing one.
    var verts = try pen.verticesForJoin(
        self.slope,
        .{ .dx = -self.slope.dx, .dy = -self.slope.dy },
        clockwise,
    );
    defer verts.deinit();
    if (verts.items.len == 0) {
        try self.capButt(result, clockwise);
    } else {
        for (verts.items) |v| {
            try result.append(
                .{
                    .x = self.p1.x + v.point.x,
                    .y = self.p1.y + v.point.y,
                },
            );
        }
    }
}
