const std = @import("std");
const debug = @import("std").debug;
const math = @import("std").math;
const mem = @import("std").mem;

const options = @import("../options.zig");
const spline = @import("spline_transformer.zig");
const units = @import("../units.zig");
const nodepkg = @import("nodes.zig");

const Face = @import("face.zig");

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

        // Init the node iterator state that we will use to process our nodes.
        // We use a separate state and functions within that to keep things
        // clean and also allow for recursion (e.g. on curve_to -> line_to).
        var state = StrokeNodeIteratorState.init(
            it.alloc,
            it.thickness,
            it.join_mode,
            it.miter_limit,
        );
        defer state.deinit();

        while (it.index < it.items.items.len) : (it.index += 1) {
            if (!(try state.process(it.items.items[it.index]))) {
                // Special case: When breaking, we need to increment on
                // close_path if this is our current node. This is because we
                // actually want to move to the next move_to the next time the
                // iterator is called.
                if (it.items.items[it.index] == .close_path) {
                    it.index += 1;
                }

                break;
            }
        }

        if (state.initial_point_) |initial_point| {
            if (state.current_point_) |current_point| {
                if (initial_point.equal(current_point) and state.joins.items.items.len == 0) {
                    // This means that the line was never effectively moved to
                    // another point, so we should not draw anything.
                    return std.ArrayList(nodepkg.PathNode).init(it.alloc);
                }
                if (state.first_line_point_) |first_line_point| {
                    if (state.last_point_) |last_point| {
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
                            state.joins.lenAll() + 5,
                        );
                        errdefer result.deinit();

                        // What we do to add points depends on if we're a
                        // closed path, or whether or not we have joins.
                        if (state.closed) {
                            // Closed path; we draw two polygons, one for each
                            // side of our stroke.
                            //
                            // NOTE: This part of the state machine should only
                            // be reached if we have joins as well, so we
                            // assert that here.
                            debug.assert(state.joins.lenAll() > 0);

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
                            for (state.joins.items.items) |j| {
                                for (j.outer.items) |point| {
                                    try result.append(.{ .line_to = .{ .point = point } });
                                }
                            }
                            try result.append(.{ .close_path = .{} });

                            // Inner joins
                            try result.append(.{ .move_to = .{ .point = start_join.inner } });
                            {
                                var i: i32 = @intCast(state.joins.items.items.len - 1);
                                while (i >= 0) : (i -= 1) {
                                    try result.append(
                                        .{ .line_to = .{ .point = state.joins.items.items[@intCast(i)].inner } },
                                    );
                                }
                            }
                            try result.append(.{ .close_path = .{} });

                            // Reset our position after plotting
                            try result.append(.{ .move_to = .{ .point = start_join.outer.items[0] } });
                        } else if (state.joins.lenAll() > 0) {
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
                            const start_clockwise = state.joins.items.items[0].clockwise;
                            const end_clockwise = state.joins.items.items[state.joins.items.items.len - 1].clockwise;

                            // Start point
                            const start_point = if (start_clockwise)
                                cap_points_start.p0_ccw
                            else
                                cap_points_start.p0_cw;
                            try result.append(.{ .move_to = .{ .point = start_point } });

                            // Outer joins
                            for (state.joins.items.items) |j| {
                                for (j.outer.items) |point| {
                                    try result.append(.{ .line_to = .{ .point = point } });
                                }
                            }

                            // End points
                            if (end_clockwise) {
                                try result.append(.{ .line_to = .{ .point = cap_points_end.p1_ccw } });
                                try result.append(.{ .line_to = .{ .point = cap_points_end.p1_cw } });
                            } else {
                                try result.append(.{ .line_to = .{ .point = cap_points_end.p1_cw } });
                                try result.append(.{ .line_to = .{ .point = cap_points_end.p1_ccw } });
                            }

                            // Inner joins
                            {
                                var i: i32 = @intCast(state.joins.items.items.len - 1);
                                while (i >= 0) : (i -= 1) {
                                    try result.append(
                                        .{ .line_to = .{ .point = state.joins.items.items[@intCast(i)].inner } },
                                    );
                                }
                            }

                            // End point and close
                            try result.append(.{
                                .line_to = .{
                                    .point = if (start_clockwise)
                                        cap_points_start.p0_cw
                                    else
                                        cap_points_start.p0_ccw,
                                },
                            });
                            try result.append(.{ .close_path = .{} });

                            // Move back to the first point
                            try result.append(.{ .move_to = .{ .point = start_point } });
                        } else {
                            // Single-segment line. This can be drawn off of
                            // our start line caps.
                            const cap_points = Face.init(initial_point, current_point, it.thickness);
                            try result.append(.{ .move_to = .{ .point = cap_points.p0_ccw } });
                            try result.append(.{ .line_to = .{ .point = cap_points.p1_ccw } });
                            try result.append(.{ .line_to = .{ .point = cap_points.p1_cw } });
                            try result.append(.{ .line_to = .{ .point = cap_points.p0_cw } });
                            try result.append(.{ .close_path = .{} });
                            try result.append(.{ .move_to = .{ .point = cap_points.p0_ccw } });
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

const StrokeNodeIteratorState = struct {
    alloc: mem.Allocator,
    thickness: f64,
    join_mode: options.JoinMode,
    miter_limit: f64,

    joins: JoinSet,
    closed: bool = false,
    initial_point_: ?units.Point = null,
    first_line_point_: ?units.Point = null,
    current_point_: ?units.Point = null,
    last_point_: ?units.Point = null,

    fn init(
        alloc: mem.Allocator,
        thickness: f64,
        join_mode: options.JoinMode,
        miter_limit: f64,
    ) StrokeNodeIteratorState {
        return .{
            .alloc = alloc,
            .thickness = thickness,
            .join_mode = join_mode,
            .miter_limit = miter_limit,

            .joins = JoinSet.init(alloc),
        };
    }

    fn deinit(self: *StrokeNodeIteratorState) void {
        self.joins.deinit();
    }

    fn process(self: *StrokeNodeIteratorState, node: nodepkg.PathNode) !bool {
        switch (node) {
            .move_to => |n| {
                return self.move_to(n);
            },
            .line_to => |n| {
                return self.line_to(n);
            },
            .curve_to => |n| {
                return self.curve_to(n);
            },
            .close_path => {
                return self.close_path();
            },
        }
    }

    fn move_to(self: *StrokeNodeIteratorState, node: nodepkg.PathMoveTo) !bool {
        // move_to with initial point means we're at the end of the
        // current line
        if (self.initial_point_ != null) {
            return false;
        }

        self.initial_point_ = node.point;
        self.current_point_ = node.point;
        return true;
    }

    fn line_to(self: *StrokeNodeIteratorState, node: nodepkg.PathLineTo) !bool {
        if (self.initial_point_ != null) {
            if (self.current_point_) |current_point| {
                if (self.last_point_) |last_point| {
                    // Join the lines last -> current -> node, with
                    // the join points representing the points
                    // around current.
                    const current_join = try join(
                        self.alloc,
                        last_point,
                        current_point,
                        node.point,
                        self.thickness,
                        self.join_mode,
                        self.miter_limit,
                    );
                    try self.joins.items.append(current_join);
                }
            } else unreachable; // move_to always sets both initial and current points
            if (self.first_line_point_ == null) {
                self.first_line_point_ = node.point;
            }
            self.last_point_ = self.current_point_;
            self.current_point_ = node.point;
        } else unreachable; // line_to should never be called internally without move_to

        return true;
    }

    fn curve_to(self: *StrokeNodeIteratorState, node: nodepkg.PathCurveTo) !bool {
        if (self.initial_point_ != null) {
            if (self.current_point_) |current_point| {
                var transformed_nodes = try spline.transform(
                    self.alloc,
                    current_point,
                    node.p1,
                    node.p2,
                    node.p3,
                    0.1, // TODO: make tolerance configurable
                );
                defer transformed_nodes.deinit();

                // Curves are always joined rounded, so we temporarily override
                // the existing join method. Put this back when we're done.
                const actual_join_mode = self.join_mode;
                self.join_mode = .round;
                defer self.join_mode = actual_join_mode;

                // Iterate through the node list here. Note that this should
                // never *not* proceed, so if we ultimately end up stopping as
                // a result of this, we're in an undefined state. So we assert
                // on true (or just drop the result completely if optimized).
                //
                // TODO: We can't use full recursion here without making the
                // code "ugly" due the current lack of inferred error sets in
                // recursion. So we just short-circuit to line_to and do
                // unreachable on the rest. I have thought of just having the
                // spline transformer just return line_to directly (not via the
                // tagged union), so that might be the other path I go down.
                for (transformed_nodes.items) |tn| {
                    const proceed = switch (tn) {
                        .line_to => |tnn| try self.line_to(tnn),
                        else => unreachable, // spline transformer does not return anything else
                    };
                    debug.assert(proceed);
                }
            }
        } else unreachable; // line_to should never be called internally without move_to

        return true;
    }

    fn close_path(self: *StrokeNodeIteratorState) !bool {
        if (self.initial_point_) |initial_point| {
            if (self.current_point_) |current_point| {
                if (self.last_point_) |last_point| {
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
                            self.alloc,
                            last_point,
                            current_point,
                            initial_point,
                            self.thickness,
                            self.join_mode,
                            self.miter_limit,
                        );
                        try self.joins.items.append(current_join);

                        // Mark as closed and break.
                        //
                        // NOTE: We need to increment our iterator
                        // too, as the break here means the while
                        // loop does not do it. This is handled in
                        // the iterator though as a special case,
                        // versus in the state parser.
                        self.closed = true;
                        return false;
                    }
                }
            } else unreachable; // move_to always sets both initial and current points
        }

        // close_path should never be called internally without move_to. This
        // means that close_path should *never* return true, and if we hit a
        // point where it would, we've hit an undefined state.
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
    const clockwise = in.slope.compare(out.slope) < 0;

    // Calculate our inner join ahead of time as we may need it for miter limit
    // calculation
    const inner_join = if (clockwise) in.intersectInner(out) else in.intersectOuter(out);
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
            const miter_point = if (clockwise) in.intersectOuter(out) else in.intersectInner(out);

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
                    if (clockwise) in.p1_ccw else in.p1_cw,
                );
                try outer_joins.append(
                    if (clockwise) out.p0_ccw else out.p0_cw,
                );
            } else {
                // Under limit, we are OK to use our miter
                try outer_joins.append(miter_point);
            }
        },

        .bevel => {
            try outer_joins.append(
                if (clockwise) in.p1_ccw else in.p1_cw,
            );
            try outer_joins.append(
                if (clockwise) out.p0_ccw else out.p0_cw,
            );
        },

        .round => {
            // TODO: Make tolerance configurable
            var pen = try Pen.init(alloc, thickness, 0.1);
            defer pen.deinit();
            var verts = try pen.verticesForJoin(in, out, clockwise);
            defer verts.deinit();
            if (verts.items.len == 0) {
                // In the case where we could not find appropriate vertices for
                // a join, it's likely that our outer angle is too small. In
                // this case, just bevel the joint.
                //
                // TODO: I feel like this is going to be the case most of the
                // time for curves. As such, we should probably review this and
                // think of a better way to handle joins for the decomposed
                // splines.
                try outer_joins.append(
                    if (clockwise) in.p1_ccw else in.p1_cw,
                );
                try outer_joins.append(
                    if (clockwise) out.p0_ccw else out.p0_cw,
                );
            } else {
                for (verts.items) |v| {
                    try outer_joins.append(
                        .{
                            .x = p1.x + v.point.x,
                            .y = p1.y + v.point.y,
                        },
                    );
                }
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
                if (self.vertices.items[@intCast(i)].slope_cw.compare(from.slope) < 0)
                    low = i
                else
                    high = i;
            }

            if (self.vertices.items[@intCast(i)].slope_cw.compare(from.slope) < 0) {
                i += 1;
                if (i == vertices_len) i = 0;
            }
            start = @intCast(i);

            if (to.slope.compare(self.vertices.items[@intCast(i)].slope_ccw) >= 0) {
                low = i;
                high = i + vertices_len;
                i = (low + high) >> 1;
                while (high - low > 1) : (i = (low + high) >> 1) {
                    const j: i32 = if (i >= vertices_len) i - vertices_len else i;
                    if (self.vertices.items[@intCast(j)].slope_cw.compare(to.slope) > 0)
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
                if (from.slope.compare(self.vertices.items[@intCast(i)].slope_ccw) < 0)
                    low = i
                else
                    high = i;
            }

            if (from.slope.compare(self.vertices.items[@intCast(i)].slope_ccw) < 0) {
                i += 1;
                if (i == vertices_len) i = 0;
            }
            start = @intCast(i);

            if (self.vertices.items[@intCast(i)].slope_cw.compare(to.slope) <= 0) {
                low = i;
                high = i + vertices_len;
                i = (low + high) >> 1;
                while (high - low > 1) : (i = (low + high) >> 1) {
                    const j: i32 = if (i >= vertices_len) i - vertices_len else i;
                    if (to.slope.compare(self.vertices.items[@intCast(j)].slope_ccw) > 0)
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