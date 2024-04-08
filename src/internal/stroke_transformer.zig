const std = @import("std");
const debug = @import("std").debug;
const math = @import("std").math;
const mem = @import("std").mem;

const options = @import("../options.zig");
const spline = @import("spline_transformer.zig");
const nodepkg = @import("path_nodes.zig");

const Face = @import("Face.zig");
const Pen = @import("Pen.zig");
const Point = @import("../Point.zig");

// TODO: remove this when we make tolerance configurable
const default_tolerance: f64 = 0.1;

/// Transforms a set of PathNode into a new PathNode set that represents a
/// fillable path for a line stroke operation. The path is generated with the
/// supplied thickness.
///
/// The returned node list is owned by the caller and deinit should be
/// called on it.
pub fn transform(
    alloc: mem.Allocator,
    nodes: std.ArrayList(nodepkg.PathNode),
    thickness: f64,
    join_mode: options.JoinMode,
    miter_limit: f64,
    cap_mode: options.CapMode,
) !std.ArrayList(nodepkg.PathNode) {
    var result = std.ArrayList(nodepkg.PathNode).init(alloc);
    errdefer result.deinit();

    var it: StrokeNodeIterator = .{
        .alloc = alloc,
        .thickness = thickness,
        .items = nodes,
        .join_mode = join_mode,
        .miter_limit = miter_limit,
        .cap_mode = cap_mode,
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
    items: std.ArrayList(nodepkg.PathNode),
    index: usize = 0,
    join_mode: options.JoinMode,
    miter_limit: f64,
    cap_mode: options.CapMode,

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
                            const start_caps = try cap_points_start.cap_p0(
                                it.alloc,
                                it.cap_mode,
                                start_clockwise,
                                default_tolerance,
                            );
                            defer start_caps.deinit();
                            try result.append(.{ .move_to = .{ .point = start_caps.items[0] } });
                            for (start_caps.items[1..start_caps.items.len]) |p| {
                                try result.append(.{ .line_to = .{ .point = p } });
                            }

                            // Outer joins
                            for (state.joins.items.items) |j| {
                                for (j.outer.items) |point| {
                                    try result.append(.{ .line_to = .{ .point = point } });
                                }
                            }

                            // End points
                            const end_caps = try cap_points_end.cap_p1(
                                it.alloc,
                                it.cap_mode,
                                end_clockwise,
                                default_tolerance,
                            );
                            defer end_caps.deinit();
                            for (end_caps.items) |p| {
                                try result.append(.{ .line_to = .{ .point = p } });
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

                            // Close
                            try result.append(.{ .close_path = .{} });

                            // Move back to the first point
                            try result.append(.{ .move_to = .{ .point = start_caps.items[0] } });
                        } else {
                            // Single-segment line. This can be drawn off of
                            // our start line caps.
                            const cap_points = Face.init(initial_point, current_point, it.thickness);
                            const start_caps = try cap_points.cap_p0(
                                it.alloc,
                                it.cap_mode,
                                true,
                                default_tolerance,
                            );
                            defer start_caps.deinit();
                            const end_caps = try cap_points.cap_p1(
                                it.alloc,
                                it.cap_mode,
                                true,
                                default_tolerance,
                            );
                            defer end_caps.deinit();

                            try result.append(.{ .move_to = .{ .point = start_caps.items[0] } });
                            for (start_caps.items[1..start_caps.items.len]) |p| {
                                try result.append(.{ .line_to = .{ .point = p } });
                            }
                            for (end_caps.items) |p| {
                                try result.append(.{ .line_to = .{ .point = p } });
                            }

                            try result.append(.{ .close_path = .{} });
                            try result.append(.{ .move_to = .{ .point = start_caps.items[0] } });
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
    initial_point_: ?Point = null,
    first_line_point_: ?Point = null,
    current_point_: ?Point = null,
    last_point_: ?Point = null,

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
                    default_tolerance,
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
    outer: std.ArrayList(Point),
    inner: Point,
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
    p0: Point,
    p1: Point,
    p2: Point,
    thickness: f64,
    mode: options.JoinMode,
    miter_limit: f64,
) !Join {
    var outer_joins = std.ArrayList(Point).init(alloc);
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
            var pen = try Pen.init(alloc, thickness, default_tolerance);
            defer pen.deinit();
            var verts = try pen.verticesForJoin(in.slope, out.slope, clockwise);
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
