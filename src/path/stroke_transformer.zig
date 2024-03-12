const std = @import("std");
const debug = @import("std").debug;
const math = @import("std").math;
const mem = @import("std").mem;

const options = @import("../options.zig");
const units = @import("../units.zig");
const nodepkg = @import("nodes.zig");

// TODO: remove this
const default_miter_limit = 4;

/// Transforms a set of PathNode into a new PathNode set that represents a
/// fillable path for a line stroke operation. The path is generated with the
/// supplied thickness.
///
/// The returned node list is owned by the caller and deinit should be
/// called on it.
pub fn transform(
    alloc: mem.Allocator,
    nodes: *std.ArrayList(nodepkg.PathNode),
    thickness: f64,
    join_mode: options.JoinMode,
    miter_limit: f64,
) !std.ArrayList(nodepkg.PathNode) {
    var result = std.ArrayList(nodepkg.PathNode).init(alloc);
    errdefer result.deinit();

    var it: StrokeNodeIterator = .{
        .alloc = alloc,
        .thickness = thickness,
        .items = nodes,
        .join_mode = join_mode,
        .miter_limit = miter_limit,
    };

    while (try it.next()) |x| {
        defer x.deinit();
        try result.appendSlice(x.items);
    }

    return result;
}

/// An iterator that advances a list of PathNodes by each fillable line.
const StrokeNodeIterator = struct {
    alloc: mem.Allocator,
    thickness: f64,
    items: *const std.ArrayList(nodepkg.PathNode),
    index: usize = 0,
    join_mode: options.JoinMode,
    miter_limit: f64,

    pub fn next(it: *StrokeNodeIterator) !?std.ArrayList(nodepkg.PathNode) {
        debug.assert(it.index <= it.items.items.len);
        if (it.index >= it.items.items.len) return null;

        // Our line joins.
        var joins = JoinSet.init(it.alloc);
        defer joins.deinit();

        // Our point state for the transformer. We need at least 3 points to
        // calculate a join, so we keep track of 2 points here (last point, current
        // point) and combine that with the point being processed. The initial
        // point stores the point of our last move_to.
        //
        // We also keep track of if the path was closed.
        var closed: bool = false;
        var initial_point_: ?units.Point = null;
        var first_line_point_: ?units.Point = null;
        var current_point_: ?units.Point = null;
        var last_point_: ?units.Point = null;

        while (it.index < it.items.items.len) : (it.index += 1) {
            switch (it.items.items[it.index]) {
                .move_to => |node| {
                    // move_to with initial point means we're at the end of the
                    // current line
                    if (initial_point_ != null) break;

                    initial_point_ = node.point;
                    current_point_ = node.point;
                },
                .curve_to => {
                    if (initial_point_ != null) {
                        // TODO: handle curve_to
                    } else unreachable; // curve_to should never be called internally without move_to
                },
                .line_to => |node| {
                    if (initial_point_ != null) {
                        if (current_point_) |current_point| {
                            if (last_point_) |last_point| {
                                // Join the lines last -> current -> node, with
                                // the join points representing the points
                                // around current.
                                const current_join = try join(
                                    it.alloc,
                                    last_point,
                                    current_point,
                                    node.point,
                                    it.thickness,
                                    it.join_mode,
                                    it.miter_limit,
                                );
                                try joins.items.append(current_join);
                            }
                        } else unreachable; // move_to always sets both initial and current points
                        if (first_line_point_ == null) {
                            first_line_point_ = node.point;
                        }
                        last_point_ = current_point_;
                        current_point_ = node.point;
                    } else unreachable; // line_to should never be called internally without move_to
                },
                .close_path => {
                    if (initial_point_) |initial_point| {
                        if (current_point_) |current_point| {
                            if (last_point_) |last_point| {
                                // Only proceed if our last_point !=
                                // initial_point. For example, if we just did
                                // move_to -> line_to -> close_path, this path
                                // is degenerate and should just be drawn as a
                                // single unclosed segment. All close_path
                                // nodes are followed by move_to nodes, so the
                                // state machine will return on the next
                                // move_to anyway.
                                //
                                // TODO: This obviously does not cover every
                                // case, there will be more complex situations
                                // where a semi-degenerate path could throw the
                                // machine into this state. We will handle
                                // those eventually.
                                if (!last_point.equal(initial_point)) {
                                    // Join the lines last -> current -> initial, with
                                    // the join points representing the points
                                    // around current.
                                    const current_join = try join(
                                        it.alloc,
                                        last_point,
                                        current_point,
                                        initial_point,
                                        it.thickness,
                                        it.join_mode,
                                        it.miter_limit,
                                    );
                                    try joins.items.append(current_join);

                                    // Mark as closed and break. We need to
                                    // increment our iterator too, as the break
                                    // here means the while loop does not do it.
                                    closed = true;
                                    it.index += 1;
                                    break;
                                }
                            }
                        } else unreachable; // move_to always sets both initial and current points
                    } else unreachable; // close_path should never be called internally without move_to
                },
            }
        }

        if (initial_point_) |initial_point| {
            if (current_point_) |current_point| {
                if (initial_point.equal(current_point) and joins.items.items.len == 0) {
                    // This means that the line was never effectively moved to
                    // another point, so we should not draw anything.
                    return std.ArrayList(nodepkg.PathNode).init(it.alloc);
                }
                if (first_line_point_) |first_line_point| {
                    if (last_point_) |last_point| {
                        // Initialize the result to the size of our joins, plus 5 nodes for:
                        //
                        // * Initial move_to (outer cap point)
                        // * End cap line_to nodes
                        // * Start inner cap point
                        // * Final close_path node
                        //
                        // This will possibly change when we add more cap modes (round
                        // caps particularly may keep us from being able to
                        // pre-determine capacity).
                        var result = try std.ArrayList(nodepkg.PathNode).initCapacity(
                            it.alloc,
                            joins.lenAll() + 5,
                        );
                        errdefer result.deinit();

                        // What we do to add points depends on if we're a
                        // closed path, or whether or not we have joins.
                        if (closed) {
                            // Closed path; we draw two polygons, one for each
                            // side of our stroke.
                            //
                            // NOTE: This part of the state machine should only
                            // be reached if we have joins as well, so we
                            // assert that here.
                            debug.assert(joins.lenAll() > 0);

                            // Start join
                            var start_join = try join(
                                it.alloc,
                                current_point,
                                initial_point,
                                first_line_point,
                                it.thickness,
                                it.join_mode,
                                it.miter_limit,
                            );
                            defer start_join.deinit();
                            try result.append(.{ .move_to = .{ .point = start_join.outer.items[0] } });
                            if (start_join.outer.items.len > 1) {
                                for (start_join.outer.items[1..]) |j| {
                                    try result.append(.{ .line_to = .{ .point = j } });
                                }
                            }

                            // Outer joins
                            for (joins.items.items) |j| {
                                for (j.outer.items) |point| {
                                    try result.append(.{ .line_to = .{ .point = point } });
                                }
                            }
                            try result.append(.{ .close_path = .{} });

                            // Inner joins
                            try result.append(.{ .move_to = .{ .point = start_join.inner } });
                            {
                                var i: i32 = @intCast(joins.items.items.len - 1);
                                while (i >= 0) : (i -= 1) {
                                    try result.append(
                                        .{ .line_to = .{ .point = joins.items.items[@intCast(i)].inner } },
                                    );
                                }
                            }
                            try result.append(.{ .close_path = .{} });

                            // Reset our position after plotting
                            try result.append(.{ .move_to = .{ .point = start_join.outer.items[0] } });
                        } else if (joins.lenAll() > 0) {
                            // Open path, draw as an unclosed line, capped at
                            // the start and end.
                            const cap_points_start = Face.init(
                                initial_point,
                                first_line_point,
                                it.thickness,
                            );
                            const cap_points_end = Face.init(
                                last_point,
                                current_point,
                                it.thickness,
                            );

                            // Check our join directions so we know how to plot our cap points
                            const start_clockwise = joins.items.items[0].clockwise;
                            const end_clockwise = joins.items.items[joins.items.items.len - 1].clockwise;

                            // Start point
                            const start_point = if (start_clockwise)
                                cap_points_start.p0_ccw()
                            else
                                cap_points_start.p0_cw();
                            try result.append(.{ .move_to = .{ .point = start_point } });

                            // Outer joins
                            for (joins.items.items) |j| {
                                for (j.outer.items) |point| {
                                    try result.append(.{ .line_to = .{ .point = point } });
                                }
                            }

                            // End points
                            if (end_clockwise) {
                                try result.append(.{ .line_to = .{ .point = cap_points_end.p1_ccw() } });
                                try result.append(.{ .line_to = .{ .point = cap_points_end.p1_cw() } });
                            } else {
                                try result.append(.{ .line_to = .{ .point = cap_points_end.p1_cw() } });
                                try result.append(.{ .line_to = .{ .point = cap_points_end.p1_ccw() } });
                            }

                            // Inner joins
                            {
                                var i: i32 = @intCast(joins.items.items.len - 1);
                                while (i >= 0) : (i -= 1) {
                                    try result.append(
                                        .{ .line_to = .{ .point = joins.items.items[@intCast(i)].inner } },
                                    );
                                }
                            }

                            // End point and close
                            try result.append(.{
                                .line_to = .{
                                    .point = if (start_clockwise)
                                        cap_points_start.p0_cw()
                                    else
                                        cap_points_start.p0_ccw(),
                                },
                            });
                            try result.append(.{ .close_path = .{} });

                            // Move back to the first point
                            try result.append(.{ .move_to = .{ .point = start_point } });
                        } else {
                            // Single-segment line. This can be drawn off of
                            // our start line caps.
                            const cap_points = Face.init(initial_point, current_point, it.thickness);
                            try result.append(.{ .move_to = .{ .point = cap_points.p0_ccw() } });
                            try result.append(.{ .line_to = .{ .point = cap_points.p1_ccw() } });
                            try result.append(.{ .line_to = .{ .point = cap_points.p1_cw() } });
                            try result.append(.{ .line_to = .{ .point = cap_points.p0_cw() } });
                            try result.append(.{ .close_path = .{} });
                            try result.append(.{ .move_to = .{ .point = cap_points.p0_ccw() } });
                        }

                        // Done
                        return result;
                    } else unreachable; // line_to always sets last_point_
                } else unreachable; // the very first line_to always sets first_line_point_
            } else unreachable; // move_to sets both initial and current points
        }

        // Invalid if we've hit this point (state machine never allows initial
        // point to not be set)
        unreachable;
    }
};

const JoinSet = struct {
    items: std.ArrayList(Join),

    fn init(alloc: mem.Allocator) JoinSet {
        return .{
            .items = std.ArrayList(Join).init(alloc),
        };
    }

    fn deinit(self: *JoinSet) void {
        for (self.items.items) |item| {
            item.deinit();
        }

        self.items.deinit();
    }

    fn lenAll(self: *JoinSet) usize {
        var result: usize = 0;
        for (self.items.items) |item| {
            result += item.outer.items.len;
            result += 1;
        }

        return result;
    }
};

const Join = struct {
    outer: std.ArrayList(units.Point),
    inner: units.Point,
    clockwise: bool,

    fn deinit(self: *const Join) void {
        self.outer.deinit();
    }
};

/// Returns points for joining two lines with each other. For point
/// calculations, the lines are treated as traveling in the same direction
/// (e.g., p0 -> p1, p1 -> p2).
fn join(
    alloc: mem.Allocator,
    p0: units.Point,
    p1: units.Point,
    p2: units.Point,
    thickness: f64,
    mode: options.JoinMode,
    miter_limit: f64,
) !Join {
    var outer_joins = std.ArrayList(units.Point).init(alloc);
    errdefer outer_joins.deinit();

    const in = Face.init(p0, p1, thickness);
    const out = Face.init(p1, p2, thickness);
    const clockwise = in.slope().compare(out.slope()) < 0;

    // Calculate our inner join ahead of time as we may need it for miter limit
    // calculation
    const inner_join = if (clockwise) in.intersect_inner(out) else in.intersect_outer(out);
    switch (mode) {
        .miter => {
            // Compare the miter length to the miter limit. This is the ratio,
            // as per the definition for stroke-miterlimit in the SVG spec:
            //
            // miter-length / stroke-width
            //
            // Source:
            // https://www.w3.org/TR/SVG11/painting.html#StrokeProperties
            //
            // Get our miter point (intersection) so that we can compare it.
            const miter_point = if (clockwise) in.intersect_outer(out) else in.intersect_inner(out);

            // We do our comparison as per above, get distance as hypotenuse of
            // dy and dx between miter point and the inner join point
            const dx = miter_point.x - inner_join.x;
            const dy = miter_point.y - inner_join.y;
            const miter_length_squared = @sqrt(dx * dx + dy * dy);
            const ratio = miter_length_squared / thickness;

            // Now compare this against the miter limit, if it exceeds the
            // limit, draw a bevel instead.
            if (ratio > miter_limit) {
                try outer_joins.append(
                    if (clockwise) in.p1_ccw() else in.p1_cw(),
                );
                try outer_joins.append(
                    if (clockwise) out.p0_ccw() else out.p0_cw(),
                );
            } else {
                // Under limit, we are OK to use our miter
                try outer_joins.append(miter_point);
            }
        },

        .bevel => {
            try outer_joins.append(
                if (clockwise) in.p1_ccw() else in.p1_cw(),
            );
            try outer_joins.append(
                if (clockwise) out.p0_ccw() else out.p0_cw(),
            );
        },

        .round => {
            // TODO: Make tolerance configurable
            var pen = try Pen.init(alloc, thickness, 0.1);
            defer pen.deinit();
            var verts = try pen.verticesForJoin(in, out, clockwise);
            defer verts.deinit();
            for (verts.items) |v| {
                try outer_joins.append(
                    .{
                        .x = p1.x + v.point.x,
                        .y = p1.y + v.point.y,
                    },
                );
            }
        },
    }

    // At this point there should always be at least one outer join point
    debug.assert(outer_joins.items.len >= 1);

    return .{
        .outer = outer_joins,
        .inner = inner_join,
        .clockwise = clockwise,
    };
}

const FaceType = enum {
    horizontal,
    vertical,
    diagonal,
};

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
const Face = union(FaceType) {
    horizontal: HorizontalFace,
    vertical: VerticalFace,
    diagonal: DiagonalFace,

    /// Computes a Face from two points in the direction of p0 -> p1.
    fn init(p0: units.Point, p1: units.Point, thickness: f64) Face {
        const _slope = units.Slope.init(p0, p1);
        const width = thickness / 2;
        if (_slope.dy == 0) {
            return .{
                .horizontal = .{
                    .p0 = p0,
                    .p1 = p1,
                    .slope = _slope,
                    .offset_y = width,
                    .p0_cw = .{ .x = p0.x, .y = p0.y + math.copysign(width, _slope.dx) },
                    .p0_ccw = .{ .x = p0.x, .y = p0.y - math.copysign(width, _slope.dx) },
                    .p1_cw = .{ .x = p1.x, .y = p1.y + math.copysign(width, _slope.dx) },
                    .p1_ccw = .{ .x = p1.x, .y = p1.y - math.copysign(width, _slope.dx) },
                },
            };
        }
        if (_slope.dx == 0) {
            return .{
                .vertical = .{
                    .p0 = p0,
                    .p1 = p1,
                    .slope = _slope,
                    .offset_x = width,
                    .p0_cw = .{ .x = p0.x - math.copysign(width, _slope.dy), .y = p0.y },
                    .p0_ccw = .{ .x = p0.x + math.copysign(width, _slope.dy), .y = p0.y },
                    .p1_cw = .{ .x = p1.x - math.copysign(width, _slope.dy), .y = p1.y },
                    .p1_ccw = .{ .x = p1.x + math.copysign(width, _slope.dy), .y = p1.y },
                },
            };
        }

        const theta = math.atan2(_slope.dy, _slope.dx);
        const offset_x = thickness / 2 * @sin(theta);
        const offset_y = thickness / 2 * @cos(theta);
        return .{
            .diagonal = .{
                .p0 = p0,
                .p1 = p1,
                .slope = _slope,
                .offset_x = offset_x,
                .offset_y = offset_y,
                .p0_cw = .{ .x = p0.x - offset_x, .y = p0.y + offset_y },
                .p0_ccw = .{ .x = p0.x + offset_x, .y = p0.y - offset_y },
                .p1_cw = .{ .x = p1.x - offset_x, .y = p1.y + offset_y },
                .p1_ccw = .{ .x = p1.x + offset_x, .y = p1.y - offset_y },
            },
        };
    }

    fn slope(self: Face) units.Slope {
        return switch (self) {
            .horizontal => |f| f.slope,
            .vertical => |f| f.slope,
            .diagonal => |f| f.slope,
        };
    }

    fn p0_cw(self: Face) units.Point {
        return switch (self) {
            .horizontal => |f| f.p0_cw,
            .vertical => |f| f.p0_cw,
            .diagonal => |f| f.p0_cw,
        };
    }

    fn p0_ccw(self: Face) units.Point {
        return switch (self) {
            .horizontal => |f| f.p0_ccw,
            .vertical => |f| f.p0_ccw,
            .diagonal => |f| f.p0_ccw,
        };
    }

    fn p1_cw(self: Face) units.Point {
        return switch (self) {
            .horizontal => |f| f.p1_cw,
            .vertical => |f| f.p1_cw,
            .diagonal => |f| f.p1_cw,
        };
    }

    fn p1_ccw(self: Face) units.Point {
        return switch (self) {
            .horizontal => |f| f.p1_ccw,
            .vertical => |f| f.p1_ccw,
            .diagonal => |f| f.p1_ccw,
        };
    }

    /// Returns the intersection of the outer edges of this face and another.
    fn intersect_outer(in: Face, out: Face) units.Point {
        return switch (in) {
            .horizontal => |f| f.intersectOuter(out),
            .vertical => |f| f.intersectOuter(out),
            .diagonal => |f| f.intersectOuter(out),
        };
    }

    /// Returns the intersection of the inner edges of this face and another.
    fn intersect_inner(in: Face, out: Face) units.Point {
        return switch (in) {
            .horizontal => |f| f.intersectInner(out),
            .vertical => |f| f.intersectInner(out),
            .diagonal => |f| f.intersectInner(out),
        };
    }
};

const HorizontalFace = struct {
    p0: units.Point,
    p1: units.Point,
    slope: units.Slope,
    offset_y: f64,
    p0_cw: units.Point,
    p0_ccw: units.Point,
    p1_cw: units.Point,
    p1_ccw: units.Point,

    fn intersectOuter(in: HorizontalFace, out: Face) units.Point {
        switch (out) {
            .horizontal => {
                // We can just return our end-point outer
                return in.p1_ccw;
            },
            .vertical => |vert| {
                // Take the x/y intersection of our outer points.
                return .{
                    .x = vert.p1_ccw.x,
                    .y = in.p0_ccw.y,
                };
            },
            .diagonal => |diag| {
                // Take the x-intercept with the origin being the horizontal
                // line outer point.
                return .{
                    .x = diag.p1_ccw.x - ((diag.p1_ccw.y - in.p0_ccw.y) / diag.slope.calculate()),
                    .y = in.p0_ccw.y,
                };
            },
        }
    }
    fn intersectInner(in: HorizontalFace, out: Face) units.Point {
        switch (out) {
            .horizontal => {
                // We can just return our end-point inner
                return in.p1_cw;
            },
            .vertical => |vert| {
                // Take the x/y intersection of our inner points.
                return .{
                    .x = vert.p1_cw.x,
                    .y = in.p0_cw.y,
                };
            },
            .diagonal => |diag| {
                // Take the x-intercept with the origin being the horizontal
                // line inner point.
                return .{
                    .x = diag.p1_cw.x - ((diag.p1_cw.y - in.p0_cw.y) / diag.slope.calculate()),
                    .y = in.p0_cw.y,
                };
            },
        }
    }
};

const VerticalFace = struct {
    p0: units.Point,
    p1: units.Point,
    slope: units.Slope,
    offset_x: f64,
    p0_cw: units.Point,
    p0_ccw: units.Point,
    p1_cw: units.Point,
    p1_ccw: units.Point,

    fn intersectOuter(in: VerticalFace, out: Face) units.Point {
        switch (out) {
            .horizontal => |horiz| {
                // Take the x/y intersection of our outer points.
                return .{
                    .x = in.p0_ccw.x,
                    .y = horiz.p1_ccw.y,
                };
            },
            .vertical => {
                // We can just return our end-point outer
                return in.p1_ccw;
            },
            .diagonal => |diag| {
                // Take the y-intercept with the origin being the vertical
                // line outer point.
                return .{
                    .x = in.p0_ccw.x,
                    .y = diag.p1_ccw.y - (diag.slope.calculate() * (diag.p1_ccw.x - in.p0_ccw.x)),
                };
            },
        }
    }

    fn intersectInner(in: VerticalFace, out: Face) units.Point {
        switch (out) {
            .horizontal => |horiz| {
                // Take the x/y intersection of our inner points.
                return .{
                    .x = in.p0_cw.x,
                    .y = horiz.p1_cw.y,
                };
            },
            .vertical => {
                // We can just return our end-point inner
                return in.p1_cw;
            },
            .diagonal => |diag| {
                // Take the y-intercept with the origin being the vertical
                // line inner point.
                return .{
                    .x = in.p0_cw.x,
                    .y = diag.p1_cw.y - (diag.slope.calculate() * (diag.p1_cw.x - in.p0_cw.x)),
                };
            },
        }
    }
};

const DiagonalFace = struct {
    p0: units.Point,
    p1: units.Point,
    slope: units.Slope,
    offset_x: f64,
    offset_y: f64,
    p0_cw: units.Point,
    p0_ccw: units.Point,
    p1_cw: units.Point,
    p1_ccw: units.Point,

    fn intersectOuter(in: DiagonalFace, out: Face) units.Point {
        switch (out) {
            .horizontal => |horiz| {
                // Take the x-intercept with the origin being the horizontal
                // line outer point.
                return .{
                    .x = in.p0_ccw.x + ((horiz.p1_ccw.y - in.p0_ccw.y) / in.slope.calculate()),
                    .y = horiz.p1_ccw.y,
                };
            },
            .vertical => |vert| {
                // Take the y-intercept with the origin being the vertical
                // line outer point.
                return .{
                    .x = vert.p1_ccw.x,
                    .y = in.p0_ccw.y + (in.slope.calculate() * (vert.p1_ccw.x - in.p0_ccw.x)),
                };
            },
            .diagonal => |diag| {
                return intersect(in.p0_ccw, diag.p1_ccw, in.slope.calculate(), diag.slope.calculate());
            },
        }
    }

    fn intersectInner(in: DiagonalFace, out: Face) units.Point {
        switch (out) {
            .horizontal => |horiz| {
                // Take the x-intercept with the origin being the horizontal
                // line outer point.
                return .{
                    .x = in.p0_cw.x + ((horiz.p1_cw.y - in.p0_cw.y) / in.slope.calculate()),
                    .y = horiz.p1_cw.y,
                };
            },
            .vertical => |vert| {
                // Take the y-intercept with the origin being the vertical
                // line outer point.
                return .{
                    .x = vert.p1_cw.x,
                    .y = in.p0_cw.y + (in.slope.calculate() * (vert.p1_cw.x - in.p0_cw.x)),
                };
            },
            .diagonal => |diag| {
                return intersect(in.p0_cw, diag.p1_cw, in.slope.calculate(), diag.slope.calculate());
            },
        }
    }
};

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

const PenVertex = struct {
    point: units.Point,
    slope_cw: units.Slope,
    slope_ccw: units.Slope,
};

/// A Pen represents a circular area designed for specific stroking operations,
/// such as round joins and caps.
const Pen = struct {
    alloc: mem.Allocator,

    /// The vertices, centered around (0,0) and distributed on even angles
    /// around the pen.
    vertices: std.ArrayList(PenVertex),

    /// Initializes a pen at radius thickness / 2, with point distribution
    /// based on the maximum error along the radius, being equal to or less
    /// than tolerance.
    fn init(alloc: mem.Allocator, thickness: f64, tolerance: f64) !Pen {
        // You can find the proof for our calculation here in cairo-pen.c in
        // the Cairo project (https://www.cairographics.org/, MPL 1.1). It
        // shows that ultimately, the maximum error of an ellipse is along its
        // major axis, and to get our needed number of vertices, we can
        // calculate the following:
        //
        // ceil(2 * Π / acos(1 - tolerance / M))
        //
        // Where M is the major axis.
        //
        // Note that since we haven't implemented transformations yet, our only
        // axis is the radius of the circular pen (thickness / 2). Once we
        // implement transformations (TODO btw), we can adjust this to be the
        // ellipse major axis.
        const radius = thickness / 2;
        const num_vertices: usize = verts: {
            // Note that our minimum number of vertices is always 4. There are
            // also situations where our tolerance may be so high that we'd
            // have a degenerate pen, so we just return 1 in that case.
            if (tolerance >= radius * 4) {
                // Degenerate pen when our tolerance is higher than what would
                // be represented by the circle itself.
                break :verts 1;
            } else if (tolerance >= radius) {
                // Not degenerate, but can fast-path here as the tolerance is
                // so high we are going to need to represent it with the
                // minimum points anyway.
                break :verts 4;
            }

            // Calculate our delta first just in case we fall on zero for some
            // reason, and break on the minimum if it is.
            const delta = math.acos(1 - tolerance / radius);
            if (delta == 0) {
                break :verts 4;
            }

            // Regular calculation can be done now
            const n: i32 = @intFromFloat(@ceil(2 * math.pi / delta));
            if (n < 4) {
                // Below minimum
                break :verts 4;
            } else if (@rem(n, 2) != 0) {
                // Add a point for uneven vertex counts
                break :verts @intCast(n + 1);
            }

            break :verts @intCast(n);
        };

        // We can now initialize and plot our vertices
        var vertices = try std.ArrayList(PenVertex).initCapacity(alloc, num_vertices);
        errdefer vertices.deinit();

        // Add the points in a first pass
        for (0..num_vertices) |i| {
            const theta: f64 = 2 * math.pi * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(num_vertices));
            const dx = radius * @cos(theta);
            const dy = radius * @sin(theta);
            try vertices.append(.{
                .point = .{ .x = dx, .y = dy },
                .slope_cw = undefined,
                .slope_ccw = undefined,
            });
        }

        // Add the slopes in a separate pass so that we can add them relative
        // to the vertices surrounding it.
        for (0..num_vertices) |i| {
            const next = if (i >= num_vertices - 1) 0 else i + 1;
            const prev = if (i == 0) num_vertices - 1 else i - 1;
            vertices.items[i].slope_cw = units.Slope.init(
                vertices.items[prev].point,
                vertices.items[i].point,
            );
            vertices.items[i].slope_ccw = units.Slope.init(
                vertices.items[i].point,
                vertices.items[next].point,
            );
        }

        return .{
            .alloc = alloc,
            .vertices = vertices,
        };
    }

    fn deinit(self: *Pen) void {
        self.vertices.deinit();
    }

    /// Gets the vertices for the join range from one face to the other,
    /// depending on the line direction.
    ///
    /// The caller owns the ArrayList and must call deinit on it.
    fn verticesForJoin(self: *Pen, from: Face, to: Face, clockwise: bool) !std.ArrayList(PenVertex) {
        var result = std.ArrayList(PenVertex).init(self.alloc);
        errdefer result.deinit();

        // Some of this logic was transcribed from cairo-slope.c in the Cairo
        // project (https://www.cairographics.org, MPL 1.1).
        //
        // The algorithm is basically a binary search back from the middle of
        // the vertex set. We search backwards for the vertex right after the
        // outer point of the end of the inbound face (i.e., the unjoined
        // stroke). This process is then repeated for the other direction to
        // locate the vertex right before the outer point of the start of the
        // outbound face.

        // Check the direction of the join so that we can return the
        // appropriate vertices in the correct order.
        var start: usize = 0;
        var end: usize = 0;
        const vertices_len: i32 = @intCast(self.vertices.items.len);
        if (clockwise) {
            // Clockwise join
            var low: i32 = 0;
            var high: i32 = vertices_len;
            var i: i32 = (low + high) >> 1;
            while (high - low > 1) : (i = (low + high) >> 1) {
                if (self.vertices.items[@intCast(i)].slope_cw.compare(from.slope()) < 0)
                    low = i
                else
                    high = i;
            }

            if (self.vertices.items[@intCast(i)].slope_cw.compare(from.slope()) < 0) {
                i += 1;
                if (i == vertices_len) i = 0;
            }
            start = @intCast(i);

            if (to.slope().compare(self.vertices.items[@intCast(i)].slope_ccw) >= 0) {
                low = i;
                high = i + vertices_len;
                i = (low + high) >> 1;
                while (high - low > 1) : (i = (low + high) >> 1) {
                    const j: i32 = if (i >= vertices_len) i - vertices_len else i;
                    if (self.vertices.items[@intCast(j)].slope_cw.compare(to.slope()) > 0)
                        high = i
                    else
                        low = i;
                }

                if (i >= vertices_len) i -= vertices_len;
            }

            end = @intCast(i);
        } else {
            // Counter-clockwise join
            var low: i32 = 0;
            var high: i32 = vertices_len;
            var i: i32 = (low + high) >> 1;
            while (high - low > 1) : (i = (low + high) >> 1) {
                if (from.slope().compare(self.vertices.items[@intCast(i)].slope_ccw) < 0)
                    low = i
                else
                    high = i;
            }

            if (from.slope().compare(self.vertices.items[@intCast(i)].slope_ccw) < 0) {
                i += 1;
                if (i == vertices_len) i = 0;
            }
            start = @intCast(i);

            if (self.vertices.items[@intCast(i)].slope_cw.compare(to.slope()) <= 0) {
                low = i;
                high = i + vertices_len;
                i = (low + high) >> 1;
                while (high - low > 1) : (i = (low + high) >> 1) {
                    const j: i32 = if (i >= vertices_len) i - vertices_len else i;
                    if (to.slope().compare(self.vertices.items[@intCast(j)].slope_ccw) > 0)
                        high = i
                    else
                        low = i;
                }

                if (i >= vertices_len) i -= vertices_len;
            }

            end = @intCast(i);
        }

        var idx = start;
        if (clockwise) {
            while (idx != end) : ({
                idx += 1;
                if (idx == vertices_len) idx = 0;
            }) {
                try result.append(self.vertices.items[idx]);
            }
        } else {
            while (idx != end) : ({
                if (idx == 0) idx = @intCast(vertices_len);
                idx -= 1;
            }) {
                try result.append(self.vertices.items[idx]);
            }
        }

        return result;
    }
};
