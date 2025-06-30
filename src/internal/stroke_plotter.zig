// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024-2025 Chris Marchesi

const std = @import("std");
const debug = @import("std").debug;
const math = @import("std").math;
const mem = @import("std").mem;
const testing = @import("std").testing;

const dashed_plotter = @import("dashed_plotter.zig");
const nodepkg = @import("path_nodes.zig");
const options = @import("../options.zig");

const Dasher = @import("Dasher.zig");
const Face = @import("Face.zig");
const Pen = @import("Pen.zig");
const PlotterVTable = @import("PlotterVTable.zig");
const Point = @import("Point.zig");
const Polygon = @import("Polygon.zig");
const Slope = @import("Slope.zig");
const Spline = @import("Spline.zig");
const Transformation = @import("../Transformation.zig");
const PointBuffer = @import("util.zig").PointBuffer(2, 5);

const InternalError = @import("InternalError.zig").InternalError;
pub const Error = InternalError || mem.Allocator.Error;

pub const PlotterOptions = struct {
    cap_mode: options.CapMode,
    ctm: Transformation,
    dashes: []const f64,
    dash_offset: f64,
    join_mode: options.JoinMode,
    miter_limit: f64,
    scale: f64,
    thickness: f64,
    tolerance: f64,
};

pub fn plot(
    alloc: mem.Allocator,
    nodes: []const nodepkg.PathNode,
    opts: PlotterOptions,
) Error!Polygon {
    if (Dasher.validate(opts.dashes)) {
        return dashed_plotter.plot(alloc, nodes, opts);
    }

    var plotter: Plotter = .{
        .alloc = alloc,
        .nodes = nodes,
        .opts = &opts,

        .pen = if (opts.join_mode == .round or opts.cap_mode == .round)
            try Pen.init(alloc, opts.thickness, opts.tolerance, opts.ctm)
        else
            null,

        .result = .{},
        .outer = .{ .scale = opts.scale },
        .inner = .{ .scale = opts.scale },
    };

    errdefer {
        plotter.result.deinit(alloc);
        plotter.outer.deinit(alloc);
        plotter.inner.deinit(alloc);
    }

    defer if (plotter.pen) |*p| p.deinit(alloc);

    try plotter.run();

    return plotter.result;
}

const Plotter = struct {
    alloc: mem.Allocator,
    nodes: []const nodepkg.PathNode,
    opts: *const PlotterOptions,

    pen: ?Pen, // pen (lazy-initialized)

    points: PointBuffer = .{}, // point buffer (initial and join points)
    clockwise_: ?bool = null, // clockwise state

    result: Polygon, // Result polygon
    outer: Polygon.Contour, // Current polygon (outer)
    inner: Polygon.Contour, // Current polygon (inner)

    fn run(self: *Plotter) Error!void {
        for (0..self.nodes.len) |idx| {
            switch (self.nodes[idx]) {
                .move_to => |n| try self.runMoveTo(n),
                .line_to => |n| try self.runLineTo(n),
                .curve_to => |n| try self.runCurveTo(n),
                .close_path => try self.runClosePath(),
            }
        }

        try self.finish();
    }

    fn runMoveTo(self: *Plotter, node: nodepkg.PathMoveTo) Error!void {
        if (self.points.len > 0) try self.finish();
        self.points.reset();
        self.points.add(node.point);
    }

    fn runLineTo(self: *Plotter, node: nodepkg.PathLineTo) Error!void {
        try self._runLineTo(self.opts.join_mode, node);
    }

    fn _runLineTo(self: *Plotter, join_mode: options.JoinMode, node: nodepkg.PathLineTo) Error!void {
        const current_point = self.points.last() orelse return InternalError.InvalidState;
        if (node.point.equal(current_point)) {
            // consume degenerate nodes
            return;
        }
        self.points.add(node.point);
        if (self.points.len > 2) {
            try join(
                Plotter,
                self,
                join_mode,
                self.points.tail(3) orelse unreachable,
                self.points.tail(2) orelse unreachable,
                self.points.tail(1) orelse unreachable,
                null,
            );
        }
    }

    fn runCurveTo(self: *Plotter, node: nodepkg.PathCurveTo) Error!void {
        const current_point = self.points.last() orelse return InternalError.InvalidState;
        // Lazy-init the pen if it has not been initialized. It
        // does not need to be de-initialized here (nor should it),
        // deinit on the plotter will take care of it.
        if (self.pen == null) self.pen = try Pen.init(
            self.alloc,
            self.opts.thickness,
            self.opts.tolerance,
            self.opts.ctm,
        );
        var plotter_ctx: CurveToCtx = .{ .plotter = self };
        var spline: Spline = .{
            .a = current_point,
            .b = node.p1,
            .c = node.p2,
            .d = node.p3,
            .tolerance = self.opts.tolerance,
            .plotter_impl = &.{
                .ptr = &plotter_ctx,
                .line_to = CurveToCtx.line_to,
            },
        };
        try spline.decompose();
    }

    fn runClosePath(self: *Plotter) Error!void {
        switch (self.points.len) {
            0 => {}, //Nothing
            1 => try self.plotDotted(self.points.first() orelse unreachable),
            2 => try plotSingle(
                Plotter,
                self,
                self.points.head(0) orelse unreachable,
                self.points.head(1) orelse unreachable,
            ),
            else => try plotClosedJoined(
                Plotter,
                self,
                self.points.head(0) orelse unreachable,
                self.points.head(1) orelse unreachable,
                self.points.tail(2) orelse unreachable,
                self.points.tail(1) orelse unreachable,
            ),
        }
        self.points.reset();
    }

    fn finish(self: *Plotter) Error!void {
        switch (self.points.len) {
            0, 1 => {}, // Nothing
            2 => try plotSingle(
                Plotter,
                self,
                self.points.head(0) orelse unreachable,
                self.points.head(1) orelse unreachable,
            ),
            else => try plotOpenJoined(
                Plotter,
                self,
                self.points.head(0) orelse unreachable,
                self.points.head(1) orelse unreachable,
                self.points.tail(2) orelse unreachable,
                self.points.tail(1) orelse unreachable,
            ),
        }
    }

    fn plotDotted(self: *Plotter, point: Point) Error!void {
        // Closed degenerate line of a length == 0. When the cap style is
        // round, we draw a circle around the point (as if both ends were
        // round-capped).
        //
        // All other zero-length strokes draw nothing.
        //
        // Note that we draw rectangles/squares for dashed lines, see this
        // function in the dashed plotter for more details.
        debug.assert(self.inner.corners.len == 0); // should have not been used
        if (self.opts.cap_mode == .round) {
            // Just plot off all of the pen's vertices, no need to
            // determine a subset as we're doing a 360-degree plot.
            debug.assert(self.pen != null);
            for (self.pen.?.vertices.items) |v| {
                try self.outer.plot(
                    self.alloc,
                    .{
                        .x = point.x + v.point.x,
                        .y = point.y + v.point.y,
                    },
                    null,
                );
            }

            // Convert our contour to edges
            try self.result.addEdgesFromContour(self.alloc, self.outer);

            // Done, de-allocate our contour corners now that they have been
            // converted to edges, and reset our states (only need to do outer,
            // as inner was not touched).
            self.outer.deinit(self.alloc);
            self.outer = .{ .scale = self.opts.scale };
            self.clockwise_ = null;
        }
    }

    pub const CurveToCtx = struct {
        plotter: *Plotter,

        fn line_to(ctx: *anyopaque, err_: *?PlotterVTable.Error, node: nodepkg.PathLineTo) void {
            const self: *CurveToCtx = @ptrCast(@alignCast(ctx));
            self.plotter._runLineTo(.round, node) catch |err| {
                err_.* = err;
            };
        }
    };
};

pub fn plotSingle(T: type, self: *T, start: Point, end: Point) Error!void {
    // Single-segment line. This can be drawn off of
    // our start line caps.
    debug.assert(self.inner.corners.len == 0); // should have not been used
    const cap_points = Face.init(
        start,
        end,
        self.opts.thickness,
        self.opts.ctm,
    );
    var plotter_ctx: CapPlotterCtx = .{
        .alloc = self.alloc,
        .contour = &self.outer,
        .before = null,
    };
    try cap_points.cap_p0(
        &.{
            .ptr = &plotter_ctx,
            .line_to = CapPlotterCtx.line_to,
        },
        self.opts.cap_mode,
        true,
        self.pen,
    );
    try cap_points.cap_p1(
        &.{
            .ptr = &plotter_ctx,
            .line_to = CapPlotterCtx.line_to,
        },
        self.opts.cap_mode,
        true,
        self.pen,
    );

    // Convert our contour to edges
    try self.result.addEdgesFromContour(self.alloc, self.outer);

    // Done, de-allocate our contour corners now that they have been converted
    // to edges, and reset our states (only need to do outer, as inner was not
    // touched).
    self.outer.deinit(self.alloc);
    self.outer = .{ .scale = self.opts.scale };
    self.clockwise_ = null;
}

pub fn plotOpenJoined(
    T: type,
    self: *T,
    start0: Point,
    end0: Point,
    start1: Point,
    end1: Point,
) Error!void {
    // Open path, plot our cap ends and concatenate
    // outer and inner.
    const cap_points_start = Face.init(
        start0,
        end0,
        self.opts.thickness,
        self.opts.ctm,
    );
    const cap_points_end = Face.init(
        start1,
        end1,
        self.opts.thickness,
        self.opts.ctm,
    );

    // Check our direction so we know how to plot our cap points
    const clockwise = if (self.clockwise_) |cw| cw else true;

    // Start point
    var outer_start_ctx: CapPlotterCtx = .{
        .alloc = self.alloc,
        .contour = &self.outer,
        .before = self.outer.corners.first,
    };
    try cap_points_start.cap_p0(
        &.{
            .ptr = &outer_start_ctx,
            .line_to = CapPlotterCtx.line_to,
        },
        self.opts.cap_mode,
        clockwise,
        self.pen,
    );

    // End point
    outer_start_ctx.before = null;
    try cap_points_end.cap_p1(
        &.{
            .ptr = &outer_start_ctx,
            .line_to = CapPlotterCtx.line_to,
        },
        self.opts.cap_mode,
        clockwise,
        self.pen,
    );

    // Now, concat the end of the inner contour to the end of the outer to give
    // a single contour (polyline) representing the whole open stroke.
    self.outer.concat(&self.inner);

    // Convert our completed contour to edges
    try self.result.addEdgesFromContour(self.alloc, self.outer);

    // Deinit our contour now that it's converted, and reset the state. Note
    // that we don't need to deinit the inner contour as all its corners were
    // moved to the outer.
    self.outer.deinit(self.alloc);
    self.outer = .{ .scale = self.opts.scale };
    self.inner = .{ .scale = self.opts.scale };
    self.clockwise_ = null;
}

pub fn plotClosedJoined(
    T: type,
    self: *T,
    initial0: Point,
    initial1: Point,
    p1: Point,
    p2: Point,
) Error!void {
    // Fully closed path, record the final join, and then
    // insert a join at the start of each the already plotted
    // inner and outer polygons. Append both.
    if (!p2.equal(initial0)) {
        // Normal case - current point does not equal the initial point.
        //
        // Do the final join (close_path acts as line_to to initial point), and
        // then join around the initial point.
        try join(T, self, self.opts.join_mode, p1, p2, initial0, null);
        try join(T, self, self.opts.join_mode, p2, initial0, initial1, null);
    } else {
        // Degenerate case - the current point is equal to the initial point.
        //
        // This will happen when a line_to or equivalent has already been
        // processed previously to the initial point. In this case, the final
        // join (p1 -> p2 -> initial0 as per above in the normal case) will
        // have already been done, and our points will have essentially shifted
        // up so that effectively p1 takes the place of p2. This means that we
        // only need to join p1 -> initial0 -> initial1 as our closing join.
        try join(T, self, self.opts.join_mode, p1, initial0, initial1, null);
    }

    // Convert both of our outer and inner contours to edges, as they both
    // represent two different closed polygons.
    try self.result.addEdgesFromContour(self.alloc, self.outer);
    try self.result.addEdgesFromContour(self.alloc, self.inner);

    // Done, de-allocate our contour corners now that they have been converted
    // to edges, and reset our states.
    self.outer.deinit(self.alloc);
    self.inner.deinit(self.alloc);
    self.outer = .{ .scale = self.opts.scale };
    self.inner = .{ .scale = self.opts.scale };
    self.clockwise_ = null;
}

pub fn join(
    T: type,
    self: *T,
    join_mode: options.JoinMode,
    p0: Point,
    p1: Point,
    p2: Point,
    before_outer: ?*Polygon.Contour.CornerList.Node,
) mem.Allocator.Error!void {
    const Joiner = struct {
        const Self = @This();

        plotter: *T,
        plot_fn: *const fn (
            *const @This(),
            *?mem.Allocator.Error,
            Point,
            ?*Polygon.Contour.CornerList.Node,
        ) void,

        fn plot(
            this: *const Self,
            point: Point,
            before: ?*Polygon.Contour.CornerList.Node,
        ) mem.Allocator.Error!void {
            var err_: ?mem.Allocator.Error = null;
            this.plot_fn(this, &err_, point, before);
            if (err_) |err| return err;
        }

        fn plotOuter(
            this: *const Self,
            err_: *?mem.Allocator.Error,
            point: Point,
            before: ?*Polygon.Contour.CornerList.Node,
        ) void {
            this.plotter.outer.plot(this.plotter.alloc, point, before) catch |err| {
                err_.* = err;
                return;
            };
        }

        fn plotInner(
            this: *const Self,
            err_: *?mem.Allocator.Error,
            point: Point,
            before: ?*Polygon.Contour.CornerList.Node,
        ) void {
            _ = before;
            this.plotter.inner.plotReverse(this.plotter.alloc, point) catch |err| {
                err_.* = err;
                return;
            };
        }
    };

    // Guard against no-op joins - if one of our segments is degenerate, just return.
    if (p0.equal(p1) or p1.equal(p2)) {
        if (self.clockwise_ == null) self.clockwise_ = false;
        return;
    }

    const in = Face.init(p0, p1, self.opts.thickness, self.opts.ctm);
    const out = Face.init(p1, p2, self.opts.thickness, self.opts.ctm);
    const join_clockwise = in.dev_slope.compare(out.dev_slope) < 0;

    // Calculate if the join direction is different from the larger
    // polygon's clockwise direction. If it is, we need to plot respective
    // points on the opposite sides of what you would normally expect to
    // preserve correct edge order and prevent twisting. We use vtables to
    // avoid the constant need to branch while plotting.
    const poly_clockwise = if (self.clockwise_) |cw| cw else join_clockwise;
    const direction_switched: bool = if (join_clockwise != poly_clockwise) true else false;
    const outer_joiner: Joiner = if (direction_switched) .{
        .plotter = self,
        .plot_fn = Joiner.plotInner,
    } else .{
        .plotter = self,
        .plot_fn = Joiner.plotOuter,
    };
    const inner_joiner: Joiner = if (direction_switched) .{
        .plotter = self,
        .plot_fn = Joiner.plotOuter,
    } else .{
        .plotter = self,
        .plot_fn = Joiner.plotInner,
    };

    // If our slopes are equal (co-linear), only plot the end of the
    // inbound face, regardless of join mode.
    if (in.dev_slope.compare(out.dev_slope) == 0) {
        try outer_joiner.plot(
            if (join_clockwise) in.p1_ccw else in.p1_cw,
            before_outer,
        );
        try inner_joiner.plot(
            if (join_clockwise) in.p1_cw else in.p1_ccw,
            before_outer,
        );
        if (self.clockwise_ == null) self.clockwise_ = poly_clockwise;
        return;
    }

    switch (join_mode) {
        .miter, .bevel => {
            if (join_mode == .miter and
                Slope.compare_for_miter_limit(in.dev_slope, out.dev_slope, self.opts.miter_limit))
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
            debug.assert(self.pen != null);
            var vit = self.pen.?.vertexIteratorFor(in.dev_slope, out.dev_slope, join_clockwise);
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

    if (self.clockwise_ == null) self.clockwise_ = poly_clockwise;
}

const CapPlotterCtx = struct {
    alloc: mem.Allocator,
    contour: *Polygon.Contour,
    before: ?*Polygon.Contour.CornerList.Node,

    fn line_to(ctx: *anyopaque, err_: *?PlotterVTable.Error, node: nodepkg.PathLineTo) void {
        const self: *CapPlotterCtx = @ptrCast(@alignCast(ctx));
        self.contour.plot(self.alloc, node.point, self.before) catch |err| {
            err_.* = err;
            return;
        };
    }
};

test "assert ok: degenerate moveto -> lineto, then good lineto" {
    {
        // p0 -> p1 is equal
        const alloc = testing.allocator;
        var nodes: std.ArrayListUnmanaged(nodepkg.PathNode) = .{};
        defer nodes.deinit(alloc);
        try nodes.append(alloc, .{ .move_to = .{ .point = .{ .x = 10, .y = 10 } } });
        try nodes.append(alloc, .{ .line_to = .{ .point = .{ .x = 10, .y = 10 } } });
        try nodes.append(alloc, .{ .line_to = .{ .point = .{ .x = 20, .y = 20 } } });

        var result = try plot(alloc, nodes.items, .{
            .cap_mode = .butt,
            .ctm = Transformation.identity,
            .dashes = &.{},
            .dash_offset = 0,
            .join_mode = .miter,
            .miter_limit = 10,
            .scale = 1,
            .thickness = 2,
            .tolerance = 0.01,
        });
        defer result.deinit(alloc);
        try testing.expectEqual(4, result.edges.items.len);
    }

    {
        // p1 -> p2 is equal
        const alloc = testing.allocator;
        var nodes: std.ArrayListUnmanaged(nodepkg.PathNode) = .{};
        defer nodes.deinit(alloc);
        try nodes.append(alloc, .{ .move_to = .{ .point = .{ .x = 10, .y = 10 } } });
        try nodes.append(alloc, .{ .line_to = .{ .point = .{ .x = 20, .y = 20 } } });
        try nodes.append(alloc, .{ .line_to = .{ .point = .{ .x = 20, .y = 20 } } });

        var result = try plot(alloc, nodes.items, .{
            .cap_mode = .butt,
            .ctm = Transformation.identity,
            .dashes = &.{},
            .dash_offset = 0,
            .join_mode = .miter,
            .miter_limit = 10,
            .scale = 1,
            .thickness = 2,
            .tolerance = 0.01,
        });
        defer result.deinit(alloc);
        try testing.expectEqual(4, result.edges.items.len);
    }
}

test "slope difference below epsilon does not produce NaN" {
    {
        // p1 -> p2 is equal
        const alloc = testing.allocator;
        var nodes: std.ArrayListUnmanaged(nodepkg.PathNode) = .{};
        defer nodes.deinit(alloc);
        try nodes.append(
            alloc,
            .{ .move_to = .{ .point = .{ .x = 2.8641015625e2, .y = 1.43154296875e1 } } },
        );
        try nodes.append(
            alloc,
            .{ .line_to = .{ .point = .{ .x = 2.822548828125e2, .y = 1.6e1 } } },
        );
        try nodes.append(
            alloc,
            .{ .line_to = .{ .point = .{ .x = 2.80990234375e2, .y = 1.65126953125e1 } } },
        );

        var result = try plot(alloc, nodes.items, .{
            .cap_mode = .butt,
            .ctm = Transformation.identity,
            .dashes = &.{},
            .dash_offset = 0,
            .join_mode = .miter,
            .miter_limit = 10,
            .scale = 1,
            .thickness = 2,
            .tolerance = 0.01,
        });
        defer result.deinit(alloc);
        try testing.expectEqual(6, result.edges.items.len);
        for (result.edges.items, 0..) |edge, idx| {
            inline for (@typeInfo(Polygon.Edge).@"struct".fields) |f| {
                if (@typeInfo(f.type) == .float) {
                    if (!math.isFinite(@field(edge, f.name))) {
                        debug.print("Non-finite value found at index {}, data: {}\n", .{ idx, edge });
                        return error.TestExpectedFinite;
                    }
                }
            }
        }
    }
}
