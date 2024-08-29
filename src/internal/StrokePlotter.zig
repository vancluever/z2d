// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024 Chris Marchesi

//! A polygon plotter for stroke operations.
const StrokePlotter = @This();

const std = @import("std");
const debug = @import("std").debug;
const mem = @import("std").mem;
const testing = @import("std").testing;

const options = @import("../options.zig");
const nodepkg = @import("path_nodes.zig");

const Face = @import("Face.zig");
const Pen = @import("Pen.zig");
const Point = @import("Point.zig");
const Slope = @import("Slope.zig");
const Spline = @import("Spline.zig");
const Polygon = @import("Polygon.zig");
const PolygonList = @import("PolygonList.zig");
const InternalError = @import("../errors.zig").InternalError;

thickness: f64,
join_mode: options.JoinMode,
miter_limit: f64,
cap_mode: options.CapMode,
pen: Pen,
scale: f64,
tolerance: f64,

pub fn init(
    alloc: mem.Allocator,
    thickness: f64,
    join_mode: options.JoinMode,
    miter_limit: f64,
    cap_mode: options.CapMode,
    scale: f64,
    tolerance: f64,
) !StrokePlotter {
    return .{
        .thickness = thickness,
        .join_mode = join_mode,
        .miter_limit = miter_limit,
        .cap_mode = cap_mode,
        .pen = try Pen.init(alloc, thickness, tolerance),
        .scale = scale,
        .tolerance = tolerance,
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
        // clean and also allow for recursion (e.g. on curve_to -> line_to).
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
                    if (state.closed) {
                        // Closed degenerate line of a length == 0. This is
                        // handled in special cases:
                        //
                        // * When the cap style is round, we draw a circle around
                        // the point (as if both ends were round-capped).
                        //
                        // * (TODO) When the cap style is square, and we are in an
                        // "on" segment in a dashed stroke, we draw a square,
                        // oriented in the direction of the stroke.
                        //
                        // All other zero-length strokes draw nothing.
                        if (state.it.plotter.cap_mode == .round) {
                            // Just plot off all of the pen's vertices, no need to
                            // determine a subset as we're doing a 360-degree plot.
                            for (state.it.plotter.pen.vertices.items) |v| {
                                try state.outer.plot(
                                    .{
                                        .x = current_point.x + v.point.x,
                                        .y = current_point.y + v.point.y,
                                    },
                                    null,
                                );
                            }

                            // Deinit inner here as it was never used
                            state.inner.deinit();

                            // Done
                            return .{ .open = state.outer };
                        }
                    }

                    // No special case applies, return empty polygon.
                    //
                    // TODO: This also currently happens on the end of a stroke
                    // path due to the implicit move_to, we could probably fix
                    // this so that we skip this part altogether by just
                    // advancing 2 versus 1 on the last close_path node. We
                    // could possibly just change this to an assert afterwards.
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
                            if (state.outer.corners.len == 0) return InternalError.InvalidState;
                            if (state.inner.corners.len == 0) return InternalError.InvalidState;
                            if (state.clockwise_ == null) return InternalError.InvalidState;
                            const outer_start_node = state.outer.corners.first;
                            _ = try it.join(
                                &state.outer,
                                &state.inner,
                                current_point,
                                initial_point,
                                first_line_point,
                                state.clockwise_,
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

                            // Check our direction so we know how to plot our cap points
                            const clockwise = if (state.clockwise_) |cw| cw else false;

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
                                clockwise,
                            );

                            // End point
                            outer_start_ctx.before = null;
                            try cap_points_end.cap_p1(
                                &.{
                                    .ptr = &outer_start_ctx,
                                    .line_to = CapPlotterCtx.line_to,
                                },
                                it.plotter.cap_mode,
                                clockwise,
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
                    } else return InternalError.InvalidState; // line_to always sets last_point_
                } else return InternalError.InvalidState; // the very first line_to always sets first_line_point_
            } else return InternalError.InvalidState; // move_to sets both initial and current points
        }

        // Invalid if we've hit this point (state machine never allows initial
        // point to not be set)
        return InternalError.InvalidState;
    }

    /// Returns points for joining two lines with each other. For point
    /// calculations, the lines are treated as traveling in the same direction
    /// (e.g., p0 -> p1, p1 -> p2).
    ///
    /// Returns either the existing polygon's clockwise direction, or an
    /// initial direction if one is not passed in through poly_clockwise_.
    fn join(
        it: *Iterator,
        outer: *Polygon,
        inner: *Polygon,
        p0: Point,
        p1: Point,
        p2: Point,
        poly_clockwise_: ?bool,
        before_outer: ?*Polygon.CornerList.Node,
    ) !bool {
        const Joiner = struct {
            polygon: *Polygon,
            plot_fn: *const fn (*anyopaque, *?anyerror, Point, ?*Polygon.CornerList.Node) void,

            fn plot(self: *const @This(), point: Point, before: ?*Polygon.CornerList.Node) !void {
                var err_: ?anyerror = null;
                self.plot_fn(self.polygon, &err_, point, before);
                if (err_) |err| return err;
            }

            fn plotOuter(
                ctx: *anyopaque,
                err_: *?anyerror,
                point: Point,
                before: ?*Polygon.CornerList.Node,
            ) void {
                const polygon: *Polygon = @ptrCast(@alignCast(ctx));
                polygon.plot(point, before) catch |err| {
                    err_.* = err;
                    return;
                };
            }

            fn plotInner(
                ctx: *anyopaque,
                err_: *?anyerror,
                point: Point,
                before: ?*Polygon.CornerList.Node,
            ) void {
                const polygon: *Polygon = @ptrCast(@alignCast(ctx));
                _ = before;
                polygon.plotReverse(point) catch |err| {
                    err_.* = err;
                    return;
                };
            }
        };

        // Guard against no-op joins - if one of our segments is degenerate, just return.
        if (p0.equal(p1) or p1.equal(p2)) return if (poly_clockwise_) |cw| cw else false;

        const in = Face.init(p0, p1, it.plotter.thickness, it.plotter.pen);
        const out = Face.init(p1, p2, it.plotter.thickness, it.plotter.pen);
        const join_clockwise = in.slope.compare(out.slope) < 0;

        // Calculate if the join direction is different from the larger
        // polygon's clockwise direction. If it is, we need to plot respective
        // points on the opposite sides of what you would normally expect to
        // preserve correct edge order and prevent twisting. We use vtables to
        // avoid the constant need to branch while plotting.
        const poly_clockwise = if (poly_clockwise_) |cw| cw else join_clockwise;
        const direction_switched: bool = if (join_clockwise != poly_clockwise) true else false;
        const outer_joiner: Joiner = if (direction_switched) .{
            .polygon = inner,
            .plot_fn = Joiner.plotInner,
        } else .{
            .polygon = outer,
            .plot_fn = Joiner.plotOuter,
        };
        const inner_joiner: Joiner = if (direction_switched) .{
            .polygon = outer,
            .plot_fn = Joiner.plotOuter,
        } else .{
            .polygon = inner,
            .plot_fn = Joiner.plotInner,
        };

        // If our slopes are equal (co-linear), only plot the end of the
        // inbound face, regardless of join mode.
        if (in.slope.compare(out.slope) == 0) {
            try outer_joiner.plot(
                if (join_clockwise) in.p1_ccw else in.p1_cw,
                before_outer,
            );
            try inner_joiner.plot(
                if (join_clockwise) in.p1_cw else in.p1_ccw,
                before_outer,
            );
            return poly_clockwise;
        }

        switch (it.plotter.join_mode) {
            .miter, .bevel => {
                if (it.plotter.join_mode == .miter and
                    Slope.compare_for_miter_limit(in.slope, out.slope, it.plotter.miter_limit))
                {
                    try outer_joiner.plot(in.intersect(out, join_clockwise), before_outer);
                } else {
                    try outer_joiner.plot(
                        if (join_clockwise) in.p1_ccw else in.p1_cw,
                        before_outer,
                    );
                    try outer_joiner.plot(
                        if (join_clockwise) out.p0_ccw else out.p0_cw,
                        before_outer,
                    );
                }
            },

            .round => {
                var vit = it.plotter.pen.vertexIteratorFor(in.slope, out.slope, join_clockwise);
                try outer_joiner.plot(
                    if (join_clockwise) in.p1_ccw else in.p1_cw,
                    before_outer,
                );
                while (vit.next()) |v| {
                    try outer_joiner.plot(
                        .{
                            .x = p1.x + v.point.x,
                            .y = p1.y + v.point.y,
                        },
                        before_outer,
                    );
                }
                try outer_joiner.plot(
                    if (join_clockwise) out.p0_ccw else out.p0_cw,
                    before_outer,
                );
            },
        }

        // Inner join. We plot our ends depending on direction, going through
        // the midpoint.
        try inner_joiner.plot(if (join_clockwise) in.p1_cw else in.p1_ccw, before_outer);
        try inner_joiner.plot(p1, before_outer);
        try inner_joiner.plot(if (join_clockwise) out.p0_cw else out.p0_ccw, before_outer);

        return poly_clockwise;
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
        clockwise_: ?bool = null,

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
                            self.clockwise_,
                            null,
                        );
                        if (self.clockwise_ == null) self.clockwise_ = clockwise;
                    }
                } else return InternalError.InvalidState; // move_to always sets both initial and current points
                if (self.first_line_point_ == null) {
                    self.first_line_point_ = node.point;
                }
                self.last_point_ = self.current_point_;
                self.current_point_ = node.point;
            } else return InternalError.InvalidState; // line_to should never be called internally without move_to

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
                        .tolerance = self.it.plotter.tolerance,
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
            } else return InternalError.InvalidState; // curve_to should never be called internally without move_to

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
                                self.clockwise_,
                                null,
                            );
                            if (self.clockwise_ == null) self.clockwise_ = clockwise;
                        }
                    }
                } else return InternalError.InvalidState; // move_to always sets both initial and current points

                // Mark as closed and break.
                //
                // NOTE: We need to increment our iterator too, as the break
                // here means the while loop does not do it. This is handled in
                // the iterator though as a special case, versus in the state
                // parser.
                self.closed = true;
                return false;
            }

            // close_path should never be called internally without move_to. This
            // means that close_path should *never* return true, and if we hit a
            // point where it would, we've hit an undefined state.
            return InternalError.InvalidState;
        }
    };
};

test "assert ok: degenerate moveto -> lineto, then good lineto" {
    {
        // p0 -> p1 is equal
        const alloc = testing.allocator;
        var nodes = std.ArrayList(nodepkg.PathNode).init(alloc);
        defer nodes.deinit();
        try nodes.append(.{ .move_to = .{ .point = .{ .x = 10, .y = 10 } } });
        try nodes.append(.{ .line_to = .{ .point = .{ .x = 10, .y = 10 } } });
        try nodes.append(.{ .line_to = .{ .point = .{ .x = 20, .y = 20 } } });

        var plotter = try StrokePlotter.init(alloc, 2, .miter, 10, .butt, 1, 0.01);
        defer plotter.deinit();

        var result = try plotter.plot(alloc, nodes);
        defer result.deinit();
        try testing.expectEqual(1, result.polygons.items.len);
        var corners_len: usize = 0;
        var next_: ?*Polygon.CornerList.Node = result.polygons.items[0].corners.first;
        while (next_) |n| {
            corners_len += 1;
            next_ = n.next;
        }
        try testing.expectEqual(4, corners_len);
    }

    {
        // p1 -> p2 is equal
        const alloc = testing.allocator;
        var nodes = std.ArrayList(nodepkg.PathNode).init(alloc);
        defer nodes.deinit();
        try nodes.append(.{ .move_to = .{ .point = .{ .x = 10, .y = 10 } } });
        try nodes.append(.{ .line_to = .{ .point = .{ .x = 20, .y = 20 } } });
        try nodes.append(.{ .line_to = .{ .point = .{ .x = 20, .y = 20 } } });

        var plotter = try StrokePlotter.init(alloc, 2, .miter, 10, .butt, 1, 0.01);
        defer plotter.deinit();

        var result = try plotter.plot(alloc, nodes);
        defer result.deinit();
        try testing.expectEqual(1, result.polygons.items.len);
        var corners_len: usize = 0;
        var next_: ?*Polygon.CornerList.Node = result.polygons.items[0].corners.first;
        while (next_) |n| {
            corners_len += 1;
            next_ = n.next;
        }
        try testing.expectEqual(4, corners_len);
    }
}
