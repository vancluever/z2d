// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024-2025 Chris Marchesi

const std = @import("std");
const debug = @import("std").debug;
const mem = @import("std").mem;
const testing = @import("std").testing;

const options = @import("../options.zig");
const nodepkg = @import("path_nodes.zig");

const Dasher = @import("Dasher.zig");
const Face = @import("Face.zig");
const Pen = @import("Pen.zig");
const PlotterVTable = @import("PlotterVTable.zig");
const Point = @import("Point.zig");
const Polygon = @import("Polygon.zig");
const PolygonList = @import("PolygonList.zig");
const Slope = @import("Slope.zig");
const Spline = @import("Spline.zig");
const Transformation = @import("../Transformation.zig");

const join = @import("stroke_plotter.zig").join;
const plotOpenJoined = @import("stroke_plotter.zig").plotOpenJoined;
const plotSingle = @import("stroke_plotter.zig").plotSingle;
const PointBuffer = @import("stroke_plotter.zig").PointBuffer;
const PlotterOptions = @import("stroke_plotter.zig").PlotterOptions;

const InternalError = @import("InternalError.zig").InternalError;
const Error = @import("stroke_plotter.zig").Error;

pub fn plot(
    alloc: mem.Allocator,
    nodes: []const nodepkg.PathNode,
    opts: PlotterOptions,
) Error!PolygonList {
    // NOTE: `opts.dashes` needs to be validated separately before calling this
    // - this is done from `stroke_plotter.plot` in normal operation. Be
    // cognizant of this if you plan on calling this directly!
    var plotter: Plotter = .{
        .alloc = alloc,
        .nodes = nodes,
        .opts = &opts,

        .pen = if (opts.join_mode == .round or opts.cap_mode == .round)
            try Pen.init(alloc, opts.thickness, opts.tolerance, opts.ctm)
        else
            null,

        .result = .{},
        .poly_outer = .{ .scale = opts.scale },
        .poly_inner = .{ .scale = opts.scale },

        .dasher = Dasher.init(opts.dashes, opts.dash_offset),
    };

    errdefer {
        plotter.result.deinit(alloc);
        plotter.poly_outer.deinit(alloc);
        plotter.poly_inner.deinit(alloc);
    }

    defer if (plotter.pen) |*p| p.deinit(alloc);

    try plotter.run();

    return plotter.result;
}

const Plotter = struct {
    const InitialPolygon = struct {
        alloc: mem.Allocator,
        opts: *const PlotterOptions,
        pen: ?Pen,
        points: PointBuffer,
        clockwise_: ?bool,
        result: *PolygonList,
        poly_outer: Polygon,
        poly_inner: Polygon,
        current_slope: Slope,
    };

    alloc: mem.Allocator,
    nodes: []const nodepkg.PathNode,
    opts: *const PlotterOptions,

    pen: ?Pen, // pen (lazy-initialized)

    points: PointBuffer = .{}, // point buffer (initial and join points)
    clockwise_: ?bool = null, // clockwise state

    result: PolygonList, // Result polygon
    poly_outer: Polygon, // Current polygon (outer)
    poly_inner: Polygon, // Current polygon (inner)

    dasher: Dasher,
    current_slope: Slope = undefined, // normalized current device slope (see _lineTo)
    initial_polygon: union(enum) { none: void, off: Point, on: InitialPolygon } = .{ .none = {} },

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
        try self.finish();
        self.dasher.reset();
        self.points.reset();
        self.points.add(node.point);
    }

    fn runLineTo(self: *Plotter, node: nodepkg.PathLineTo) Error!void {
        return self._runLineTo(self.opts.join_mode, node);
    }

    fn _runLineTo(
        self: *Plotter,
        join_mode: options.JoinMode,
        node: nodepkg.PathLineTo,
    ) Error!void {
        if (self.points.idx <= 0) return InternalError.InvalidState;
        if (node.point.equal(self.points.items[self.points.idx - 1])) {
            // consume degenerate nodes
            return;
        }
        const first_dash_point = self.points.items[self.points.idx - 1];
        var slope = Slope.init(first_dash_point, node.point);
        self.current_slope = slope;
        _ = self.current_slope.normalize();
        self.opts.ctm.deviceToUserDistance(&slope.dx, &slope.dy) catch unreachable;
        const total_len = slope.normalize();
        var remaining_len = total_len;
        var step_len = @min(self.dasher.remain, remaining_len);
        while (remaining_len > 0) : (step_len = @min(self.dasher.remain, remaining_len)) {
            remaining_len -= step_len;
            var x_offset = slope.dx * (total_len - remaining_len);
            var y_offset = slope.dy * (total_len - remaining_len);
            self.opts.ctm.userToDeviceDistance(&x_offset, &y_offset);
            const current_dash_point: Point = .{
                .x = first_dash_point.x + x_offset,
                .y = first_dash_point.y + y_offset,
            };
            if (!current_dash_point.equal(self.points.items[self.points.idx - 1])) {
                // Only add this point if it's different than the point
                // before it, this allows us to plot dots (and squares
                // also), i.e., zero-length dash stops.
                self.points.add(current_dash_point);
            }
            if (self.dasher.on) {
                if (self.points.idx > 2) {
                    try join(
                        Plotter,
                        self,
                        join_mode,
                        self.points.items[self.points.idx - 3],
                        self.points.items[self.points.idx - 2],
                        self.points.items[self.points.idx - 1],
                        null,
                    );
                }
            }
            if (self.dasher.step(step_len)) {
                try self.nextSegment(current_dash_point);
            }
        }
    }

    fn runCurveTo(self: *Plotter, node: nodepkg.PathCurveTo) Error!void {
        if (self.points.idx <= 0) return InternalError.InvalidState;
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
            .a = self.points.items[self.points.idx - 1],
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
        if (self.points.idx <= 0) return InternalError.InvalidState;
        // Unlike non-dashed close_path, we need to dash to our initial
        // point to ensure that any dashes inbetween are taken care of.
        try self._runLineTo(self.opts.join_mode, .{
            .point = switch (self.initial_polygon) {
                .on => |poly| pt: {
                    debug.assert(poly.points.idx > 0);
                    break :pt poly.points.items[0];
                },
                .off => |initial_point| initial_point,
                else => self.points.items[0],
            },
        });
        // How we close now depends on whether or not we actually dashed.
        switch (self.initial_polygon) {
            .on => |poly| {
                // Check the current dasher state
                if (self.dasher.on and self.points.idx > 1) {
                    // We're on, so we need to join our last segment to the
                    // initial polygon.
                    debug.assert(poly.points.idx > 0);
                    if (poly.points.idx == 1) {
                        // Our initial polygon was a dot (zero-length dash).
                        // Since we actually have already plotted back to our
                        // original point, we can just treat this as a
                        // last-segment dash off our current state.
                        try plotOpenJoined(
                            Plotter,
                            self,
                            self.points.items[0],
                            self.points.items[1],
                            self.points.items[self.points.idx - 2],
                            self.points.items[self.points.idx - 1],
                        );
                        // Reset the initial state since we're not invoking
                        // a helper that does it.
                        self.initial_polygon = .{ .none = {} };
                    } else {
                        try self.joinAndCapInitial();
                    }
                } else {
                    // We're off, or we just transitioned to an on segment at
                    // exactly the original point, so cap off the initial using
                    // the original initial points.
                    debug.assert(poly.points.idx > 0);
                    if (poly.points.idx == 1) {
                        // Zero-length dash, plot a dot
                        try self.finishInitialDotted();
                    } else try self.finishInitial(
                        poly.points.items[0],
                        poly.points.items[1],
                    );
                }
            },
            .off => {
                // Nothing - we've already drawn back to the initial point.
                // Just reset the initial polygon state.
                self.initial_polygon = .{ .none = {} };
            },
            .none => {
                // We never actually transitioned off the initial dash segment.
                // This almost acts like an undashed closed path, but since
                // we've already advanced to our end point in the above line_to
                // call, we need to act accordingly.
                switch (self.points.idx) {
                    0 => unreachable,
                    1 => try self.plotDotted(self.points.items[0], self.current_slope),
                    2 => try plotSingle(
                        Plotter,
                        self,
                        self.points.items[0],
                        self.points.items[1],
                    ),
                    else => {
                        // We only need to plot the final join here, since
                        // we've already plotted the first.
                        //
                        // Join around the initial point
                        try join(
                            Plotter,
                            self,
                            self.opts.join_mode,
                            self.points.items[self.points.idx - 2],
                            self.points.items[0],
                            self.points.items[1],
                            null,
                        );

                        // Done
                        try self.result.prepend(self.alloc, self.poly_outer);
                        try self.result.prepend(self.alloc, self.poly_inner);
                        self.poly_outer = .{ .scale = self.opts.scale };
                        self.poly_inner = .{ .scale = self.opts.scale };
                        self.clockwise_ = null;
                    },
                }
            },
        }
        self.points.reset();
    }

    fn nextSegment(self: *Plotter, point: Point) Error!void {
        if (self.initial_polygon == .none)
            self.saveInitial()
        else if (!self.dasher.on) {
            switch (self.points.idx) {
                0 => {}, //Nothing
                1 => try self.plotDotted(self.points.items[0], self.current_slope),
                2 => try plotSingle(
                    Plotter,
                    self,
                    self.points.items[0],
                    self.points.items[1],
                ),
                else => try plotOpenJoined(
                    Plotter,
                    self,
                    self.points.items[0],
                    self.points.items[1],
                    self.points.items[self.points.idx - 2],
                    self.points.items[self.points.idx - 1],
                ),
            }
        }
        self.points.reset();
        self.points.add(point);
    }

    fn finish(self: *Plotter) Error!void {
        switch (self.initial_polygon) {
            .on => |poly| {
                debug.assert(poly.points.idx > 0);
                if (poly.points.idx == 1) {
                    try self.finishInitialDotted();
                } else try self.finishInitial(
                    poly.points.items[0],
                    poly.points.items[1],
                );
            },
            .off => self.initial_polygon = .{ .none = {} },
            .none => {},
        }
        if (self.dasher.on) switch (self.points.idx) {
            0 => {}, //Nothing
            1 => try self.plotDotted(self.points.items[0], self.current_slope),
            2 => try plotSingle(
                Plotter,
                self,
                self.points.items[0],
                self.points.items[1],
            ),
            else => try plotOpenJoined(
                Plotter,
                self,
                self.points.items[0],
                self.points.items[1],
                self.points.items[self.points.idx - 2],
                self.points.items[self.points.idx - 1],
            ),
        };
    }

    fn plotDotted(self: *Plotter, point: Point, current_slope: Slope) Error!void {
        // Closed degenerate line of a length == 0. This is handled in special
        // cases:
        //
        // * When the cap style is round, we draw a circle around the point (as
        // if both ends were round-capped).
        //
        // * When the cap style is square, and we are in an "on" segment in a
        // dashed stroke, we draw a square, oriented in the direction of the
        // stroke.
        //
        // All other zero-length strokes draw nothing.
        debug.assert(self.poly_inner.corners.len == 0); // should have not been used
        switch (self.opts.cap_mode) {
            .round => {
                // Just plot off all of the pen's vertices, no need to
                // determine a subset as we're doing a 360-degree plot.
                debug.assert(self.pen != null);
                for (self.pen.?.vertices.items) |v| {
                    try self.poly_outer.plot(
                        self.alloc,
                        .{
                            .x = point.x + v.point.x,
                            .y = point.y + v.point.y,
                        },
                        null,
                    );
                }

                // Done
                try self.result.prepend(self.alloc, self.poly_outer);
            },
            .square => {
                // "cap" a single point with the last slope we've logged in
                // a line_to or close_path. We just take a subset of
                // capSquare in face, while still computing the offsets
                // using some of the init functionality.
                //
                // TODO: This (honestly, along with Face in general) is due
                // for a refactor so that we can de-atomize some of the
                // more common functionality here. There's currently only a
                // few wasted ops _maybe_ (additions on the extra point
                // that are not needed), but it would be nice to be able to
                // be confident and be able to say that there's no risk of
                // any due to over-abstraction and code re-use.
                const face = Face.initSingle(
                    point,
                    current_slope,
                    self.opts.thickness,
                    self.opts.ctm,
                );
                var offset_x = face.user_slope.dx * face.half_width;
                var offset_y = face.user_slope.dy * face.half_width;
                self.opts.ctm.userToDeviceDistance(&offset_x, &offset_y);
                try self.poly_outer.plot(
                    self.alloc,
                    .{
                        .x = face.p1_cw.x - offset_x,
                        .y = face.p1_cw.y - offset_y,
                    },
                    null,
                );
                try self.poly_outer.plot(
                    self.alloc,
                    .{
                        .x = face.p1_cw.x + offset_x,
                        .y = face.p1_cw.y + offset_y,
                    },
                    null,
                );
                try self.poly_outer.plot(
                    self.alloc,
                    .{
                        .x = face.p1_ccw.x + offset_x,
                        .y = face.p1_ccw.y + offset_y,
                    },
                    null,
                );
                try self.poly_outer.plot(
                    self.alloc,
                    .{
                        .x = face.p1_ccw.x - offset_x,
                        .y = face.p1_ccw.y - offset_y,
                    },
                    null,
                );
                // Done
                try self.result.prepend(self.alloc, self.poly_outer);
            },
            else => {},
        }
        self.poly_outer = .{ .scale = self.opts.scale }; // reset outer
        self.clockwise_ = null;
    }

    fn saveInitial(
        self: *Plotter,
    ) void {
        // This prepares the initial polygon for later capping or joining,
        // depending on the final state of the stroke. The thing is that we
        // don't necessarily know if we're dealing with a close_path or
        // not, and if the stroker state will be on or not in that close.
        // So this tracks as much state as we need to make a decision at
        // that point.
        if (!self.dasher.on) {
            // This is intended to be used on dash step transitions, so we
            // save if the dasher state was off.
            //
            // Note that there are some duplication of fields from the plotter
            // here (alloc, options, pen) to ensure that we can just use the
            // initial polygon with our generic plotting helpers (join and
            // plotOpenJoined). This should be of no concern and minimal
            // overhead (allocator and opts are just pointers, and the pen
            // solely contains an ArrayListUnmanaged so is not much more than
            // that). The only possible concern is the fact that the pen is
            // lazy-initialized and could be done so later than the initial
            // polygon in a curve_to. However, in that case, it's only used for
            // round-joining the decomposed lines and as such would not be
            // needed for joining or capping anything connecting to the initial
            // polygons anyway.
            self.initial_polygon = .{ .on = .{
                .alloc = self.alloc,
                .opts = self.opts,
                .pen = self.pen,
                .points = self.points,
                .clockwise_ = self.clockwise_,
                .result = &self.result,
                .poly_outer = self.poly_outer,
                .poly_inner = self.poly_inner,
                .current_slope = self.current_slope,
            } };
        } else {
            // We record that the initial dash state was off and discard
            // any data in the off segment, minus the initial point, which
            // we need for a possible close_path in the sub-path we're
            // currently in. This can happen when dash offsets have
            // pushed/pulled the state into an off segment at the start of
            // the stroke.
            debug.assert(self.points.idx > 0);
            self.initial_polygon = .{ .off = self.points.items[0] };
        }

        // Reset other polygon stuff
        self.poly_outer = .{ .scale = self.opts.scale }; // reset outer
        self.poly_inner = .{ .scale = self.opts.scale }; // reset inner
        self.clockwise_ = null;
    }

    fn finishInitialDotted(
        self: *Plotter,
    ) Error!void {
        debug.assert(self.initial_polygon == .on);
        debug.assert(self.initial_polygon.on.points.idx > 0);
        try self.plotDotted(
            self.initial_polygon.on.points.items[0],
            self.initial_polygon.on.current_slope,
        );
        self.initial_polygon = .{ .none = {} };
    }

    fn finishInitial(
        self: *Plotter,
        last_point: Point,
        second_to_last_point: Point,
    ) Error!void {
        debug.assert(self.initial_polygon == .on);
        debug.assert(self.initial_polygon.on.points.idx >= 2);

        try plotOpenJoined(
            InitialPolygon,
            &self.initial_polygon.on,
            last_point,
            second_to_last_point,
            self.initial_polygon.on.points.items[self.initial_polygon.on.points.idx - 2],
            self.initial_polygon.on.points.items[self.initial_polygon.on.points.idx - 1],
        );
        self.initial_polygon = .{ .none = {} };
    }

    fn joinAndCapInitial(self: *Plotter) Error!void {
        // This adds a join at the beginning of the initial polygon before
        // capping.
        debug.assert(self.initial_polygon == .on);
        debug.assert(self.initial_polygon.on.points.idx >= 2);

        if (self.points.idx > 2) {
            // We need to actually do some polygon surgery here because we have
            // some outstanding joins.
            //
            // NOTE: This is a bit meaty, a little bit of a hack right now, but
            // it works for what we need. Could be improved upon, more than likely.

            // Do the final join on the existing polygon.
            try join(
                Plotter,
                self,
                self.opts.join_mode,
                self.points.items[self.points.idx - 2],
                self.initial_polygon.on.points.items[0],
                self.initial_polygon.on.points.items[1],
                null,
            );

            // Concat the initial polygon to the main outer, and inner to
            // initial, i.e., the other way around.
            self.poly_outer.concat(self.initial_polygon.on.poly_outer);
            self.initial_polygon.on.poly_inner.concat(self.poly_inner);
            // We need to replace the initial polygon with the outer due to the
            // direction of the concat happened in.
            self.initial_polygon.on.poly_outer = self.poly_outer;

            // Our first cap points are based entirely off of the plotter state
            // (not the initial state).
            try plotOpenJoined(
                InitialPolygon,
                &self.initial_polygon.on,
                self.points.items[0],
                self.points.items[1],
                self.initial_polygon.on.points.items[self.initial_polygon.on.points.idx - 2],
                self.initial_polygon.on.points.items[self.initial_polygon.on.points.idx - 1],
            );
        } else {
            // Don't need to do any concats and our cap points are last corner
            // -> start of initial polygon.

            // Do the join
            try join(
                InitialPolygon,
                &self.initial_polygon.on,
                self.opts.join_mode,
                self.points.items[self.points.idx - 2],
                self.initial_polygon.on.points.items[0],
                self.initial_polygon.on.points.items[1],
                self.initial_polygon.on.poly_outer.corners.first,
            );

            try plotOpenJoined(
                InitialPolygon,
                &self.initial_polygon.on,
                self.points.items[0],
                self.initial_polygon.on.points.items[0],
                self.initial_polygon.on.points.items[self.initial_polygon.on.points.idx - 2],
                self.initial_polygon.on.points.items[self.initial_polygon.on.points.idx - 1],
            );
        }

        self.initial_polygon = .{ .none = {} };
        //  Reset the main polygon state as we don't do that above (the initial
        //  gets cleared instead).
        self.poly_outer = .{ .scale = self.opts.scale };
        self.poly_inner = .{ .scale = self.opts.scale };
        self.clockwise_ = null;
    }

    const CurveToCtx = struct {
        plotter: *Plotter,

        fn line_to(ctx: *anyopaque, err_: *?PlotterVTable.Error, node: nodepkg.PathLineTo) void {
            const self: *CurveToCtx = @ptrCast(@alignCast(ctx));
            self.plotter._runLineTo(.round, node) catch |err| {
                err_.* = err;
            };
        }
    };
};
