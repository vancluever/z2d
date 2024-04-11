//! A polygon plotter for stroke operations.
const StrokePlotter = @This();

const std = @import("std");
const debug = @import("std").debug;
const mem = @import("std").mem;

const options = @import("../options.zig");
const nodepkg = @import("path_nodes.zig");

const Face = @import("Face.zig");
const Pen = @import("Pen.zig");
const Point = @import("../Point.zig");
const Spline = @import("Spline.zig");
const Polygon = @import("Polygon.zig");
const PolygonList = @import("PolygonList.zig");

// TODO: remove this when we make tolerance configurable
const default_tolerance: f64 = 0.1;

thickness: f64,
join_mode: options.JoinMode,
miter_limit: f64,
cap_mode: options.CapMode,
pen: Pen,
scale: f64,

pub fn init(
    alloc: mem.Allocator,
    thickness: f64,
    join_mode: options.JoinMode,
    miter_limit: f64,
    cap_mode: options.CapMode,
    scale: f64,
) !StrokePlotter {
    return .{
        .thickness = thickness,
        .join_mode = join_mode,
        .miter_limit = miter_limit,
        .cap_mode = cap_mode,
        .pen = try Pen.init(alloc, thickness, default_tolerance),
        .scale = scale,
    };
}

pub fn deinit(self: *StrokePlotter) void {
    self.pen.deinit();
}

pub fn plot(
    self: *StrokePlotter,
    alloc: mem.Allocator,
    nodes: std.ArrayList(nodepkg.PathNode),
) !PolygonList {
    var result = PolygonList.init(alloc);
    errdefer result.deinit();

    var it: Iterator = .{
        .plotter = self,
        .nodes = nodes,
    };

    while (try it.next(alloc)) |next| {
        errdefer next.deinit();
        switch (next) {
            .closed => |n| {
                try result.append(n[0]);
                try result.append(n[1]);
            },
            .open => |n| {
                try result.append(n);
            },
            .empty => {},
        }
    }

    return result;
}

/// An iterator that advances a list of PathNodes by each fillable line.
const Iterator = struct {
    plotter: *StrokePlotter,
    nodes: std.ArrayList(nodepkg.PathNode),
    index: usize = 0,

    const ResultPolygonType = enum {
        closed,
        open,
        empty,
    };

    const ResultPolygon = union(ResultPolygonType) {
        closed: [2]Polygon,
        open: Polygon,
        empty: struct {},

        fn deinit(self: ResultPolygon) void {
            switch (self) {
                .closed => |r| {
                    r[0].deinit();
                    r[1].deinit();
                },
                .open => |r| {
                    r.deinit();
                },
                .empty => {},
            }
        }
    };

    const CapPlotterCtx = struct {
        polygon: *Polygon,
        before: ?*Polygon.CornerList.Node,

        fn line_to(ctx: *anyopaque, err_: *?anyerror, node: nodepkg.PathLineTo) void {
            const self: *CapPlotterCtx = @ptrCast(@alignCast(ctx));
            self.polygon.plot(node.point, self.before) catch |err| {
                err_.* = err;
                return;
            };
        }
    };

    fn next(it: *Iterator, alloc: mem.Allocator) !?ResultPolygon {
        debug.assert(it.index <= it.nodes.items.len);
        if (it.index >= it.nodes.items.len) return null;

        // Init the node iterator state that we will use to process our nodes.
        // We use a separate state and functions within that to keep things
        // clean and also allow for recursion (e.g. on curve_to -> line_to).a
        var state = State.init(alloc, it);
        errdefer state.deinit();

        while (it.index < it.nodes.items.len) : (it.index += 1) {
            if (!(try state.process(it.nodes.items[it.index]))) {
                // Special case: When breaking, we need to increment on
                // close_path if this is our current node. This is because we
                // actually want to move to the next move_to the next time the
                // iterator is called.
                if (it.nodes.items[it.index] == .close_path) {
                    it.index += 1;
                }

                break;
            }
        }

        if (state.initial_point_) |initial_point| {
            if (state.current_point_) |current_point| {
                if (initial_point.equal(current_point) and state.outer.corners.len == 0) {
                    // This means that the line was never effectively moved to
                    // another point from the initial point, so we should not
                    // draw anything.
                    //
                    // TODO: This currently happens on the end of a stroke path
                    // due to the implicit move_to, we could probably fix this
                    // so that we skip this part altogether by just advancing 2
                    // versus 1 on the last close_path node. We could possibly
                    // just change this to an assert afterwards.
                    state.deinit();
                    return .{ .empty = .{} };
                }
                if (state.first_line_point_) |first_line_point| {
                    if (state.last_point_) |last_point| {
                        // What we do to add points depends on if we're a
                        // closed path, or whether or not we have joins.
                        if (state.closed) {
                            // Closed path, insert a join at the start of each
                            // the already plotted inner and outer polygons.
                            debug.assert(state.outer.corners.len != 0);
                            debug.assert(state.inner.corners.len != 0);
                            debug.assert(state.start_clockwise_ != null);
                            const outer_start_node = state.outer.corners.first;
                            _ = try it.join(
                                &state.outer,
                                &state.inner,
                                current_point,
                                initial_point,
                                first_line_point,
                                outer_start_node,
                            );

                            // Done
                            return .{ .closed = .{ state.outer, state.inner } };
                        } else if (state.outer.corners.len != 0) {
                            // Open path, plot our cap ends and concatenate
                            // outer and inner.
                            const cap_points_start = Face.init(
                                initial_point,
                                first_line_point,
                                it.plotter.thickness,
                                it.plotter.pen,
                            );
                            const cap_points_end = Face.init(
                                last_point,
                                current_point,
                                it.plotter.thickness,
                                it.plotter.pen,
                            );

                            // Check our join directions so we know how to plot our cap points
                            const start_clockwise = state.start_clockwise_.?;
                            const end_clockwise = state.end_clockwise;

                            // Start point
                            const outer_start_node = state.outer.corners.first;
                            var outer_start_ctx: CapPlotterCtx = .{
                                .polygon = &state.outer,
                                .before = outer_start_node,
                            };
                            try cap_points_start.cap_p0(
                                &.{
                                    .ptr = &outer_start_ctx,
                                    .line_to = CapPlotterCtx.line_to,
                                },
                                it.plotter.cap_mode,
                                start_clockwise,
                            );

                            // End point
                            outer_start_ctx.before = null;
                            try cap_points_end.cap_p1(
                                &.{
                                    .ptr = &outer_start_ctx,
                                    .line_to = CapPlotterCtx.line_to,
                                },
                                it.plotter.cap_mode,
                                end_clockwise,
                            );

                            // Now, concat the end of the inner polygon to the
                            // end of the outer to give a single polygon
                            // representing the whole open stroke.
                            try state.outer.concat(state.inner);

                            // Done
                            return .{ .open = state.outer };
                        } else {
                            // Single-segment line. This can be drawn off of
                            // our start line caps.
                            const cap_points = Face.init(
                                initial_point,
                                current_point,
                                it.plotter.thickness,
                                it.plotter.pen,
                            );
                            var plotter_ctx: CapPlotterCtx = .{
                                .polygon = &state.outer,
                                .before = null,
                            };
                            try cap_points.cap_p0(
                                &.{
                                    .ptr = &plotter_ctx,
                                    .line_to = CapPlotterCtx.line_to,
                                },
                                it.plotter.cap_mode,
                                true,
                            );
                            try cap_points.cap_p1(
                                &.{
                                    .ptr = &plotter_ctx,
                                    .line_to = CapPlotterCtx.line_to,
                                },
                                it.plotter.cap_mode,
                                true,
                            );

                            // Deinit inner here as it was never used
                            state.inner.deinit();

                            // Done
                            return .{ .open = state.outer };
                        }
                    } else unreachable; // line_to always sets last_point_
                } else unreachable; // the very first line_to always sets first_line_point_
            } else unreachable; // move_to sets both initial and current points
        }

        // Invalid if we've hit this point (state machine never allows initial
        // point to not be set)
        unreachable;
    }

    /// Returns points for joining two lines with each other. For point
    /// calculations, the lines are treated as traveling in the same direction
    /// (e.g., p0 -> p1, p1 -> p2).
    ///
    /// Returns if the join was clockwise or not.
    fn join(
        it: *Iterator,
        outer: *Polygon,
        inner: *Polygon,
        p0: Point,
        p1: Point,
        p2: Point,
        before_outer: ?*Polygon.CornerList.Node,
    ) !bool {
        const in = Face.init(p0, p1, it.plotter.thickness, it.plotter.pen);
        const out = Face.init(p1, p2, it.plotter.thickness, it.plotter.pen);
        const clockwise = in.slope.compare(out.slope) < 0;

        // Calculate our inner join ahead of time as we may need it for miter limit
        // calculation
        const inner_join = if (clockwise) in.intersectInner(out) else in.intersectOuter(out);
        switch (it.plotter.join_mode) {
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
                const ratio = miter_length_squared / it.plotter.thickness;

                // Now compare this against the miter limit, if it exceeds the
                // limit, draw a bevel instead.
                if (ratio > it.plotter.miter_limit) {
                    try outer.plot(
                        if (clockwise) in.p1_ccw else in.p1_cw,
                        before_outer,
                    );
                    try outer.plot(
                        if (clockwise) out.p0_ccw else out.p0_cw,
                        before_outer,
                    );
                } else {
                    // Under limit, we are OK to use our miter
                    try outer.plot(miter_point, before_outer);
                }
            },

            .bevel => {
                try outer.plot(
                    if (clockwise) in.p1_ccw else in.p1_cw,
                    before_outer,
                );
                try outer.plot(
                    if (clockwise) out.p0_ccw else out.p0_cw,
                    before_outer,
                );
            },

            .round => {
                var vit = it.plotter.pen.vertexIteratorFor(in.slope, out.slope, clockwise);
                var hasVerts = false;
                while (vit.next()) |v| {
                    hasVerts = true;
                    try outer.plot(
                        .{
                            .x = p1.x + v.point.x,
                            .y = p1.y + v.point.y,
                        },
                        before_outer,
                    );
                }
                if (!hasVerts) {
                    // In the case where we could not find appropriate vertices for
                    // a join, it's likely that our outer angle is too small. In
                    // this case, just bevel the joint.
                    //
                    // TODO: I feel like this is going to be the case most of the
                    // time for curves. As such, we should probably review this and
                    // think of a better way to handle joins for the decomposed
                    // splines.
                    try outer.plot(
                        if (clockwise) in.p1_ccw else in.p1_cw,
                        before_outer,
                    );
                    try outer.plot(
                        if (clockwise) out.p0_ccw else out.p0_cw,
                        before_outer,
                    );
                }
            },
        }

        // Plot the inner join in reverse order, this ensures we maintain the
        // correct winding order.
        try inner.plotReverse(inner_join);
        return clockwise;
    }

    const State = struct {
        it: *Iterator,

        outer: Polygon,
        inner: Polygon,

        closed: bool = false,
        initial_point_: ?Point = null,
        first_line_point_: ?Point = null,
        current_point_: ?Point = null,
        last_point_: ?Point = null,
        start_clockwise_: ?bool = null,
        end_clockwise: bool = false,

        fn init(alloc: mem.Allocator, it: *Iterator) State {
            return .{
                .it = it,
                .outer = Polygon.init(alloc, it.plotter.scale),
                .inner = Polygon.init(alloc, it.plotter.scale),
            };
        }

        fn deinit(self: *State) void {
            self.outer.deinit();
            self.inner.deinit();
        }

        fn process(self: *State, node: nodepkg.PathNode) !bool {
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

        fn move_to(self: *State, node: nodepkg.PathMoveTo) !bool {
            // move_to with initial point means we're at the end of the
            // current line
            if (self.initial_point_ != null) {
                return false;
            }

            self.initial_point_ = node.point;
            self.current_point_ = node.point;
            return true;
        }

        fn line_to(self: *State, node: nodepkg.PathLineTo) !bool {
            if (self.initial_point_ != null) {
                if (self.current_point_) |current_point| {
                    if (self.last_point_) |last_point| {
                        // Join the lines last -> current -> node, with
                        // the join points representing the points
                        // around current.
                        const clockwise = try self.it.join(
                            &self.outer,
                            &self.inner,
                            last_point,
                            current_point,
                            node.point,
                            null,
                        );
                        if (self.start_clockwise_ == null) self.start_clockwise_ = clockwise;
                        self.end_clockwise = clockwise;
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

        fn spline_line_to(ctx: *anyopaque, err_: *?anyerror, node: nodepkg.PathLineTo) void {
            const self: *State = @ptrCast(@alignCast(ctx));
            const proceed = self.line_to(node) catch |err| {
                err_.* = err;
                return;
            };
            debug.assert(proceed);
        }

        fn curve_to(self: *State, node: nodepkg.PathCurveTo) !bool {
            if (self.initial_point_ != null) {
                if (self.current_point_) |current_point| {
                    var spline: Spline = .{
                        .a = current_point,
                        .b = node.p1,
                        .c = node.p2,
                        .d = node.p3,
                        .tolerance = default_tolerance, // TODO: Make tolerance configurable
                        .plotter_impl = &.{
                            .ptr = self,
                            .line_to = spline_line_to,
                        },
                    };

                    // Curves are always joined rounded, so we temporarily override
                    // the existing join method. Put this back when we're done.
                    const actual_join_mode = self.it.plotter.join_mode;
                    self.it.plotter.join_mode = .round;
                    defer self.it.plotter.join_mode = actual_join_mode;

                    // Decompose now
                    try spline.decompose();
                }
            } else unreachable; // line_to should never be called internally without move_to

            return true;
        }

        fn close_path(self: *State) !bool {
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
                            const clockwise = try self.it.join(
                                &self.outer,
                                &self.inner,
                                last_point,
                                current_point,
                                initial_point,
                                null,
                            );
                            if (self.start_clockwise_ == null) self.start_clockwise_ = clockwise;
                            self.end_clockwise = clockwise;

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
};
