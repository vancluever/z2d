// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024-2026 Chris Marchesi

//! Input set for path effects. Includes helpers for calculation of
//! intersections, re-ordering points, and other functionality that is useful
//! to all path effect functionality that should happen at input time.
const InputSet = @This();

const std = @import("std");

const nodepkg = @import("../path_nodes.zig");

const PlotterVTable = @import("../tess/PlotterVTable.zig");
const PointBuffer = @import("../tess/point_buffer.zig").PointBuffer(1, 2);
const Point = @import("../Point.zig");
const Spline = @import("../tess/Spline.zig");

contours: std.ArrayList(Contour) = .empty,

const empty: InputSet = .{};

const InternalError = @import("../InternalError.zig").InternalError;

pub const FromNodesError = InternalError || std.mem.Allocator.Error;

/// Loads an input set from path nodes.
///
/// The following rules currently apply:
///
/// * Co-linear nodes are consolidated.
/// * Single-node paths (move_to -> close_path, or just move_to) are currently
///   ignored.
pub fn fromNodes(
    alloc: std.mem.Allocator,
    nodes: []const nodepkg.PathNode,
    tolerance: f64,
) FromNodesError!InputSet {
    // NOTE: the state machine has some duplicated logic in comparison to other
    // plotters, namely due to how we specifically flag closed contours, this
    // means that we have to append and clear out the state on both close and
    // move_to, but in the latter case only when we have nodes already (for
    // open paths). This could use a bit of a refactor to possibly remove these
    // duplicate code paths, but for now it should be fine (and is well
    // tested).

    var result: InputSet = .empty;
    errdefer result.deinit(alloc);

    var current_contour: Contour = .empty;
    // TODO: There is not much that will cause this to really trigger right now
    // in a way that releasing memory would actually be necessary. I have a
    // feeling it's like this in our other plotters as well, we should take a
    // look at that at some point.
    errdefer current_contour.deinit(alloc);

    var points: PointBuffer = .{};

    for (nodes, 0..) |node, i| {
        switch (node) {
            .move_to => |n| {
                if (current_contour.segments.items.len != 0) {
                    try result.contours.append(alloc, current_contour);
                    current_contour = .empty;
                    points.reset();
                }

                // Check if this is the last node, and no-op if it is, as this
                // is the auto-added move_to node that is given after
                // close_path.
                if (i == nodes.len - 1) {
                    break;
                }
                points.add(n.point);
            },
            .line_to => |n| {
                if (points.last()) |last_point| {
                    if (!last_point.equal(n.point)) {
                        if (current_contour.segments.items.len == 0) {
                            current_contour = try .init(alloc, last_point, n.point);
                        } else {
                            try current_contour.plot(alloc, n.point);
                        }

                        points.add(n.point);
                    }
                } else return InternalError.InvalidState;
            },
            .curve_to => |n| {
                if (points.len == 0) return InternalError.InvalidState;
                var ctx: SplinePlotterCtx = .{
                    .alloc = alloc,
                    .contour = &current_contour,
                    .points = &points,
                };
                var spline: Spline = .{
                    .a = points.last().?,
                    .b = n.p1,
                    .c = n.p2,
                    .d = n.p3,
                    .tolerance = tolerance,
                    .plotter_impl = &.{
                        .ptr = &ctx,
                        .line_to = SplinePlotterCtx.line_to,
                    },
                };
                try spline.decompose();
            },
            .close_path => {
                // Note that unlike our fill plotter, there's not much in the
                // way of special handling here, however we skip if all we have
                // in the buffer is a move_to, mainly because that would only
                // be a single point anyway.
                if (points.len >= 2) { // Our limit is 2 currently but this guards in the case we change it
                    // Close and add contour
                    try current_contour.close(alloc);
                    try result.contours.append(alloc, current_contour);
                    current_contour = .empty;

                    // Reset points (a well-formed path always has a move_to
                    // after close_point)
                    points.reset();
                }
            },
        }
    }

    if (current_contour.segments.items.len != 0) {
        try result.contours.append(alloc, current_contour);
    }

    return result;
}

pub fn deinit(self: *InputSet, alloc: std.mem.Allocator) void {
    for (self.contours.items) |*contour| {
        contour.deinit(alloc);
    }

    self.contours.deinit(alloc);
    self.* = undefined;
}

const SplinePlotterCtx = struct {
    alloc: std.mem.Allocator,
    contour: *Contour,
    points: *PointBuffer,

    fn line_to(ctx: *anyopaque, err_: *?PlotterVTable.Error, node: nodepkg.PathLineTo) void {
        const self: *SplinePlotterCtx = @ptrCast(@alignCast(ctx));
        if (self.points.last()) |last_point| {
            if (!last_point.equal(node.point)) {
                // FIXME: This is cursed
                (plot: {
                    if (self.contour.segments.items.len == 0) {
                        self.contour.* = Contour.init(self.alloc, last_point, node.point) catch |err| break :plot err;
                    } else {
                        self.contour.plot(self.alloc, node.point) catch |err| break :plot err;
                    }
                } catch |err| {
                    err_.* = err;
                    return;
                });
                self.points.add(node.point);
            }
        } else {
            err_.* = InternalError.InvalidState;
            return;
        }
    }
};

pub const Contour = struct {
    segments: std.ArrayList(Segment) = .empty,
    closed: bool = false,
    next_intersection_id: usize = 0,

    const empty: Contour = .{};

    /// Asserts that the two points are not equal.
    fn init(alloc: std.mem.Allocator, p0: Point, p1: Point) std.mem.Allocator.Error!Contour {
        var result: Contour = .empty;
        errdefer result.deinit(alloc);
        try result.segments.append(alloc, .init(p0, p1));
        return result;
    }

    fn deinit(self: *Contour, alloc: std.mem.Allocator) void {
        for (self.segments.items) |*segment| {
            segment.deinit(alloc);
        }

        self.segments.deinit(alloc);
        self.* = undefined;
    }

    /// Asserts that there is at least one segment in the contour, and that the
    /// contour is not closed. Will combine co-linear consecutive segments into
    /// single segments.
    fn plot(self: *Contour, alloc: std.mem.Allocator, point: Point) std.mem.Allocator.Error!void {
        std.debug.assert(self.segments.items.len > 0);
        std.debug.assert(!self.closed);
        const prev = self.segments.items[self.segments.items.len - 1];
        var current: Segment = .init(prev.p1, point);
        current.orientation = switch (prev.slope.compare(current.slope)) {
            -1 => .cw,
            1 => .ccw,
            else => {
                self.segments.items[self.segments.items.len - 1].p1 = point;
                return;
            },
        };

        if (self.segments.items.len == 1) {
            // Note that we set this on close as well to what its correct value
            // would be. Setting it on the second plot here to *something*
            // ensures our special case for orientation on the first segment
            // for open segments gets handled correctly (we assume there is a
            // fictional previous point going in the same direction as the
            // previous segment to this one).
            self.segments.items[0].orientation = current.orientation;
        }

        try self.segments.append(alloc, current);
    }

    /// Asserts that there is at least two segments in the contour, and that the
    /// contour is not closed.
    fn close(self: *Contour, alloc: std.mem.Allocator) std.mem.Allocator.Error!void {
        std.debug.assert(self.segments.items.len >= 2);
        std.debug.assert(!self.closed);

        plot_last: {
            const prev = self.segments.items[self.segments.items.len - 1];
            if (prev.p1.equal(self.segments.items[0].p0)) {
                // Skip adding a segment as both the ending point and initial
                // point are the same
                break :plot_last;
            }

            var current: Segment = .init(prev.p1, self.segments.items[0].p0);
            current.orientation = switch (prev.slope.compare(current.slope)) {
                -1 => .cw,
                1 => .ccw,
                else => {
                    self.segments.items[self.segments.items.len - 1].p1 = self.segments.items[0].p0;
                    break :plot_last;
                },
            };

            try self.segments.append(alloc, current);
        }

        {
            self.closed = true;
            const prev = self.segments.items[self.segments.items.len - 1];
            const current = &self.segments.items[0];
            current.orientation = if (prev.slope.compare(current.slope) < 0) .cw else .ccw;
        }
    }

    /// Aligns the segments in the contour so that the first left-most vertex
    /// encountered (defined as p0 in the Segment) is the first point. Order of
    /// the polyline is preserved, under the assumption that the polyline
    /// represents a closed contour.
    ///
    /// Asserts that the contour is closed.
    pub fn alignSegments(self: *Contour) void {
        std.debug.assert(self.closed);
        var start_idx: usize = 0;
        for (self.segments.items, 0..) |seg, new_idx| {
            if (seg.p0.x < self.segments.items[start_idx].p0.x) {
                start_idx = new_idx;
            }
        }

        // This can be optimized if need be.
        const len = self.segments.items.len;
        while (start_idx > 0) : (start_idx -= 1) {
            const tmp = self.segments.items[0];
            @memmove(self.segments.items[0 .. len - 1], self.segments.items[1..len]);
            self.segments.items[len - 1] = tmp;
        }
    }

    /// Compute the intersections for a slice of segments, populating the
    /// intersection indexes in each segment.
    pub fn computeIntersections(self: *Contour, alloc: std.mem.Allocator) std.mem.Allocator.Error!void {
        var next_id: usize = 0;
        for (self.segments.items, 0..) |*s0, s0_idx| {
            for (self.segments.items[s0_idx..], s0_idx..) |*s1, s1_idx| {
                if (Segment.intersectionFor(s0.*, s1.*)) |isect| {
                    try s0.insertIntersection(alloc, .{
                        .id = next_id,
                        .t = isect.in_t,
                        .out_idx = s1_idx,
                        .point = isect.point,
                        .orientation = if (isect.clockwise) .cw else .ccw,
                    });
                    try s1.insertIntersection(alloc, .{
                        .id = next_id,
                        .t = isect.out_t,
                        .out_idx = s0_idx,
                        .point = isect.point,
                        .orientation = if (!isect.clockwise) .cw else .ccw,
                    });
                    next_id += 1;
                }
            }
        }
    }

    pub const Segment = struct {
        p0: Point,
        p1: Point,
        orientation: Orientation = .invalid,
        intersections: std.ArrayList(Intersection) = .empty,
        slope: Slope,

        /// Asserts the two points are not equal.
        fn init(p0: Point, p1: Point) Segment {
            std.debug.assert(!p0.equal(p1));
            return .{
                .p0 = p0,
                .p1 = p1,
                .slope = .init(p0, p1),
            };
        }

        fn deinit(self: *Segment, alloc: std.mem.Allocator) void {
            self.intersections.deinit(alloc);
            self.* = undefined;
        }

        fn insertIntersection(
            self: *Segment,
            alloc: std.mem.Allocator,
            value: Intersection,
        ) std.mem.Allocator.Error!void {
            if (self.intersections.items.len == 0) {
                return self.intersections.append(alloc, value);
            }

            var low: usize = 0;
            var high: usize = self.intersections.items.len;

            while (low < high) {
                const mid = low + (high - low) / 2;
                if (self.intersections.items[mid].t < value.t) {
                    low = mid + 1;
                } else {
                    high = mid;
                }
            }

            const insertion_idx = low;
            if (insertion_idx == self.intersections.items.len) {
                return self.intersections.append(alloc, value);
            } else {
                return self.intersections.insert(alloc, insertion_idx, value);
            }
        }

        pub fn unshiftIntersection(self: *Segment) ?Intersection {
            if (self.intersections.items.len > 0) {
                return self.intersections.orderedRemove(0);
            }

            return null;
        }

        fn intersectionFor(in: Segment, out: Segment) ?IntersectionForResult {
            const x1 = in.p0.x;
            const y1 = in.p0.y;
            const x2 = in.p1.x;
            const y2 = in.p1.y;
            const x3 = out.p0.x;
            const y3 = out.p0.y;
            const x4 = out.p1.x;
            const y4 = out.p1.y;

            const Det = struct {
                fn f(a: f64, b: f64, c: f64, d: f64) f64 {
                    return a * d - b * c;
                }
            };

            // NOTE: Some writings of the divisor here write it as a
            // determinant of what is functionally:
            //   (in_dx * -out_dx - in_dy * -out_dy)
            //
            // We write it as:
            //   (in_dy * out_dx - out_dy * in_dx)
            //
            // This is so that it's consistent with our slope comparison
            // functionality, allowing us to just re-use this value instead of
            // running another compare to have consistent logic.
            const div = Det.f(y2 - y1, y4 - y3, x2 - x1, x4 - x3);
            if (div == 0) {
                return null;
            }

            const t1 = Det.f(x3 - x1, x3 - x4, y3 - y1, y3 - y4) / div;
            if (!(0 < t1 and t1 < 1)) {
                return null;
            }

            const t2 = Det.f(x2 - x1, x3 - x1, y2 - y1, y3 - y1) / div;
            if (!(0 <= t2 and t2 <= 1)) {
                return null;
            }

            return .{
                .in_t = t1,
                .out_t = t2,
                .point = .{
                    .x = x1 + t1 * (x2 - x1),
                    .y = y1 + t1 * (y2 - y1),
                },
                // NOTE: Our determinant here is functionally the same as the
                // one we use in slope comparison
                // (in_dx * -out_dx - in_dy * -out_dy == in_dy * out_dx - out_dy * in_dx).
                // I'm leaving it as-is here
                .clockwise = div < 0,
            };
        }

        const IntersectionForResult = struct {
            in_t: f64,
            out_t: f64,
            point: Point,
            clockwise: bool,
        };

        const Orientation = enum {
            invalid,
            cw,
            ccw,
        };

        const Intersection = struct {
            /// Unique within the contour. Will match the corresponding
            /// intersection in the outbound segment.
            id: usize,

            /// The parametric placement of the intersection along the inbound
            /// segment.
            t: f64,

            /// The index of the outbound segment in the contour.
            out_idx: usize,
            point: Point,
            orientation: Orientation,
        };

        /// Slope for the segment, always stored in normalized form. Reduced
        /// functionality of our slope bits used for tessellation/stroking.
        pub const Slope = struct {
            dx: f64,
            dy: f64,

            /// Asserts that a != b.
            fn init(a: Point, b: Point) Slope {
                std.debug.assert(!a.equal(b));
                const dx_real = b.x - a.x;
                const dy_real = b.y - a.y;

                if (dx_real == 0) {
                    return switch (dy_real > 0) {
                        true => .{ .dx = 0, .dy = 1 },
                        false => .{ .dx = 0, .dy = -1 },
                    };
                } else if (dy_real == 0) {
                    return switch (dx_real > 0) {
                        true => .{ .dx = 1, .dy = 0 },
                        false => .{ .dx = -1, .dy = 0 },
                    };
                }

                const mag = std.math.hypot(dx_real, dy_real);
                return .{
                    .dx = dx_real / mag,
                    .dy = dy_real / mag,
                };
            }

            fn compare(a: Slope, b: Slope) i2 {
                const a_dx = a.dx;
                const a_dy = a.dy;
                const b_dx = snapEpsTo(a.dx, b.dx);
                const b_dy = snapEpsTo(a.dy, b.dy);
                // NOTE: We don't do tie breakers here since a lot of them
                // should not apply to normalized slopes. If we need them we
                // can add them back.
                return @as(i2, std.math.sign(a_dy * b_dx - b_dy * a_dx));
            }

            fn snapEpsTo(a: f64, b: f64) f64 {
                return if (@abs(b - a) > std.math.floatEps(f64)) b else a;
            }
        };
    };
};

test "fromNodes, star" {
    const alloc = std.testing.allocator;
    const nodes = [_]nodepkg.PathNode{
        .{ .move_to = .{ .point = .{ .x = 25, .y = 5 } } },
        .{ .line_to = .{ .point = .{ .x = 32, .y = 25 } } },
        .{ .line_to = .{ .point = .{ .x = 15, .y = 13 } } },
        .{ .line_to = .{ .point = .{ .x = 35, .y = 13 } } },
        .{ .line_to = .{ .point = .{ .x = 18, .y = 25 } } },
        .{ .close_path = .{} },
        .{ .move_to = .{ .point = .{ .x = 25, .y = 5 } } },
    };

    const expected = mkExpectedSegment(&[_]MkExpectedSegmentOpts{
        .{
            .p0 = .{ .x = 25, .y = 5 },
            .p1 = .{ .x = 32, .y = 25 },
            .orientation = .cw,
        },
        .{
            .p0 = .{ .x = 32, .y = 25 },
            .p1 = .{ .x = 15, .y = 13 },
            .orientation = .cw,
        },
        .{
            .p0 = .{ .x = 15, .y = 13 },
            .p1 = .{ .x = 35, .y = 13 },
            .orientation = .cw,
        },
        .{
            .p0 = .{ .x = 35, .y = 13 },
            .p1 = .{ .x = 18, .y = 25 },
            .orientation = .cw,
        },
        .{
            .p0 = .{ .x = 18, .y = 25 },
            .p1 = .{ .x = 25, .y = 5 },
            .orientation = .cw,
        },
    });
    var got = try fromNodes(alloc, &nodes, 0.1);
    defer got.deinit(alloc);
    try std.testing.expectEqual(1, got.contours.items.len);
    try std.testing.expectEqual(true, got.contours.items[0].closed);
    try std.testing.expectEqualDeep(&expected, got.contours.items[0].segments.items);
}

test "fromNodes, one closed, one open" {
    const alloc = std.testing.allocator;

    // M 18 61 L 25 61 L 25 68 L 18 68 Z M 34 58 L 37 64 L 34 70
    const nodes = [_]nodepkg.PathNode{
        .{ .move_to = .{ .point = .{ .x = 18, .y = 61 } } },
        .{ .line_to = .{ .point = .{ .x = 25, .y = 61 } } },
        .{ .line_to = .{ .point = .{ .x = 25, .y = 68 } } },
        .{ .line_to = .{ .point = .{ .x = 18, .y = 68 } } },
        .{ .close_path = .{} },
        .{ .move_to = .{ .point = .{ .x = 18, .y = 61 } } },
        .{ .move_to = .{ .point = .{ .x = 34, .y = 58 } } },
        .{ .line_to = .{ .point = .{ .x = 37, .y = 64 } } },
        .{ .line_to = .{ .point = .{ .x = 34, .y = 70 } } },
    };

    const expected_0 = mkExpectedSegment(&[_]MkExpectedSegmentOpts{
        .{
            .p0 = .{ .x = 18, .y = 61 },
            .p1 = .{ .x = 25, .y = 61 },
            .orientation = .cw,
        },
        .{
            .p0 = .{ .x = 25, .y = 61 },
            .p1 = .{ .x = 25, .y = 68 },
            .orientation = .cw,
        },
        .{
            .p0 = .{ .x = 25, .y = 68 },
            .p1 = .{ .x = 18, .y = 68 },
            .orientation = .cw,
        },
        .{
            .p0 = .{ .x = 18, .y = 68 },
            .p1 = .{ .x = 18, .y = 61 },
            .orientation = .cw,
        },
    });

    const expected_1 = mkExpectedSegment(&[_]MkExpectedSegmentOpts{
        .{
            .p0 = .{ .x = 34, .y = 58 },
            .p1 = .{ .x = 37, .y = 64 },
            .orientation = .cw,
        },
        .{
            .p0 = .{ .x = 37, .y = 64 },
            .p1 = .{ .x = 34, .y = 70 },
            .orientation = .cw,
        },
    });

    var got = try fromNodes(alloc, &nodes, 0.1);
    defer got.deinit(alloc);
    try std.testing.expectEqual(2, got.contours.items.len);
    try std.testing.expectEqual(true, got.contours.items[0].closed);
    try std.testing.expectEqualDeep(&expected_0, got.contours.items[0].segments.items);
    try std.testing.expectEqual(false, got.contours.items[1].closed);
    try std.testing.expectEqualDeep(&expected_1, got.contours.items[1].segments.items);
}

test "fromNodes, one open, one closed" {
    const alloc = std.testing.allocator;

    // M 18 61 L 25 61 L 25 68 L 18 68 Z M 34 58 L 37 64 L 34 70
    const nodes = [_]nodepkg.PathNode{
        .{ .move_to = .{ .point = .{ .x = 34, .y = 58 } } },
        .{ .line_to = .{ .point = .{ .x = 37, .y = 64 } } },
        .{ .line_to = .{ .point = .{ .x = 34, .y = 70 } } },
        .{ .move_to = .{ .point = .{ .x = 18, .y = 61 } } },
        .{ .line_to = .{ .point = .{ .x = 25, .y = 61 } } },
        .{ .line_to = .{ .point = .{ .x = 25, .y = 68 } } },
        .{ .line_to = .{ .point = .{ .x = 18, .y = 68 } } },
        .{ .close_path = .{} },
        .{ .move_to = .{ .point = .{ .x = 18, .y = 61 } } },
    };

    const expected_0 = mkExpectedSegment(&[_]MkExpectedSegmentOpts{
        .{
            .p0 = .{ .x = 34, .y = 58 },
            .p1 = .{ .x = 37, .y = 64 },
            .orientation = .cw,
        },
        .{
            .p0 = .{ .x = 37, .y = 64 },
            .p1 = .{ .x = 34, .y = 70 },
            .orientation = .cw,
        },
    });

    const expected_1 = mkExpectedSegment(&[_]MkExpectedSegmentOpts{
        .{
            .p0 = .{ .x = 18, .y = 61 },
            .p1 = .{ .x = 25, .y = 61 },
            .orientation = .cw,
        },
        .{
            .p0 = .{ .x = 25, .y = 61 },
            .p1 = .{ .x = 25, .y = 68 },
            .orientation = .cw,
        },
        .{
            .p0 = .{ .x = 25, .y = 68 },
            .p1 = .{ .x = 18, .y = 68 },
            .orientation = .cw,
        },
        .{
            .p0 = .{ .x = 18, .y = 68 },
            .p1 = .{ .x = 18, .y = 61 },
            .orientation = .cw,
        },
    });

    var got = try fromNodes(alloc, &nodes, 0.1);
    defer got.deinit(alloc);
    try std.testing.expectEqual(2, got.contours.items.len);
    try std.testing.expectEqual(false, got.contours.items[0].closed);
    try std.testing.expectEqualDeep(&expected_0, got.contours.items[0].segments.items);
    try std.testing.expectEqual(true, got.contours.items[1].closed);
    try std.testing.expectEqualDeep(&expected_1, got.contours.items[1].segments.items);
}

test "fromNodes, bezier, open" {
    const alloc = std.testing.allocator;
    const nodes = [_]nodepkg.PathNode{
        .{ .move_to = .{ .point = .{ .x = 19, .y = 149 } } },
        .{ .curve_to = .{
            .p1 = .{ .x = 89, .y = 0 },
            .p2 = .{ .x = 209, .y = 0 },
            .p3 = .{ .x = 279, .y = 149 },
        } },
    };

    var got = try fromNodes(alloc, &nodes, 0.1);
    defer got.deinit(alloc);

    // We don't test the points themselves there will be a *ton* of segments in
    // the contour, but we can test a couple of things, like making sure that
    // all of the segments are in the clockwise direction.
    try std.testing.expectEqual(1, got.contours.items.len);
    try std.testing.expectEqual(false, got.contours.items[0].closed);
    try std.testing.expect(got.contours.items[0].segments.items.len > 0);
    for (got.contours.items[0].segments.items) |seg| {
        try std.testing.expectEqual(.cw, seg.orientation);
    }
}

test "fromNodes, closed arc is returned closed" {
    const alloc = std.testing.allocator;
    // Importing here because we don't need `Path` anywhere else
    var path: @import("../../Path.zig") = .empty;
    defer path.deinit(alloc);

    path.transformation = @import("../../Transformation.zig").identity
        .translate(100, 100)
        .scale(50, 50);
    try path.arc(alloc, 0, 0, 1, 0, 2 * std.math.pi);
    try path.close(alloc);

    var got = try fromNodes(alloc, path.nodes.items, 0.1);
    defer got.deinit(alloc);

    try std.testing.expectEqual(1, got.contours.items.len);
    try std.testing.expectEqual(true, got.contours.items[0].closed);
}

test "fromNodes, move_to -> close_path unsupported (for now)" {
    const alloc = std.testing.allocator;
    const nodes = [_]nodepkg.PathNode{
        .{ .move_to = .{ .point = .{ .x = 19, .y = 149 } } },
        .{ .close_path = .{} },
    };

    var got = try fromNodes(alloc, &nodes, 0.1);
    defer got.deinit(alloc);
    try std.testing.expectEqual(0, got.contours.items.len);
}

test "fromNodes, invalid" {
    {
        const alloc = std.testing.allocator;
        const nodes = [_]nodepkg.PathNode{
            .{ .line_to = .{ .point = .{ .x = 19, .y = 149 } } },
        };

        try std.testing.expectError(error.InvalidState, fromNodes(alloc, &nodes, 0.1));
    }

    {
        const alloc = std.testing.allocator;
        const nodes = [_]nodepkg.PathNode{
            .{ .curve_to = .{
                .p1 = .{ .x = 89, .y = 0 },
                .p2 = .{ .x = 209, .y = 0 },
                .p3 = .{ .x = 279, .y = 149 },
            } },
        };

        try std.testing.expectError(error.InvalidState, fromNodes(alloc, &nodes, 0.1));
    }

    {
        // Invalid after a valid path (ensures we release memory from already
        // added contours)
        const alloc = std.testing.allocator;
        const nodes = [_]nodepkg.PathNode{
            .{ .move_to = .{ .point = .{ .x = 25, .y = 5 } } },
            .{ .line_to = .{ .point = .{ .x = 32, .y = 25 } } },
            .{ .line_to = .{ .point = .{ .x = 15, .y = 13 } } },
            .{ .line_to = .{ .point = .{ .x = 35, .y = 13 } } },
            .{ .line_to = .{ .point = .{ .x = 18, .y = 25 } } },
            .{ .close_path = .{} },
            .{ .line_to = .{ .point = .{ .x = 19, .y = 149 } } },
        };

        try std.testing.expectError(error.InvalidState, fromNodes(alloc, &nodes, 0.1));
    }
}

test "Contour.init" {
    const alloc = std.testing.allocator;
    var got: Contour = try .init(alloc, .{ .x = 10, .y = 10 }, .{ .x = 20, .y = 20 });
    defer got.deinit(alloc);
    try std.testing.expectEqual(false, got.closed);
    try std.testing.expectEqual(1, got.segments.items.len);
    try std.testing.expectEqualDeep(Contour.Segment.init(
        .{ .x = 10, .y = 10 },
        .{ .x = 20, .y = 20 },
    ), got.segments.items[0]);
}

test "Contour.plot" {
    const alloc = std.testing.allocator;
    var got: Contour = try .init(alloc, .{ .x = 10, .y = 10 }, .{ .x = 20, .y = 20 });
    defer got.deinit(alloc);
    try got.plot(alloc, .{ .x = 20, .y = 30 });
    try std.testing.expectEqual(false, got.closed);
    const expected = mkExpectedSegment(&[_]MkExpectedSegmentOpts{
        .{
            .p0 = .{ .x = 10, .y = 10 },
            .p1 = .{ .x = 20, .y = 20 },
            .orientation = .cw,
        },
        .{
            .p0 = .{ .x = 20, .y = 20 },
            .p1 = .{ .x = 20, .y = 30 },
            .orientation = .cw,
        },
    });
    try std.testing.expectEqualDeep(&expected, got.segments.items);
}

test "Contour.plot, co-linear" {
    const alloc = std.testing.allocator;
    var got: Contour = try .init(alloc, .{ .x = 10, .y = 10 }, .{ .x = 20, .y = 20 });
    defer got.deinit(alloc);
    try got.plot(alloc, .{ .x = 30, .y = 30 });
    try std.testing.expectEqual(false, got.closed);
    try std.testing.expectEqual(1, got.segments.items.len);
    try std.testing.expectEqualDeep(Contour.Segment.init(
        .{ .x = 10, .y = 10 },
        .{ .x = 30, .y = 30 },
    ), got.segments.items[0]);
}

test "Contour.close" {
    const alloc = std.testing.allocator;
    var got: Contour = try .init(alloc, .{ .x = 10, .y = 10 }, .{ .x = 20, .y = 20 });
    defer got.deinit(alloc);
    try got.plot(alloc, .{ .x = 10, .y = 20 });
    try got.plot(alloc, .{ .x = 20, .y = 10 });
    try got.close(alloc);
    try std.testing.expectEqual(true, got.closed);
    const expected = mkExpectedSegment(&[_]MkExpectedSegmentOpts{
        .{
            .p0 = .{ .x = 10, .y = 10 },
            .p1 = .{ .x = 20, .y = 20 },
            .orientation = .ccw,
        },
        .{
            .p0 = .{ .x = 20, .y = 20 },
            .p1 = .{ .x = 10, .y = 20 },
            .orientation = .cw,
        },
        .{
            .p0 = .{ .x = 10, .y = 20 },
            .p1 = .{ .x = 20, .y = 10 },
            .orientation = .cw,
        },
        .{
            .p0 = .{ .x = 20, .y = 10 },
            .p1 = .{ .x = 10, .y = 10 },
            .orientation = .ccw,
        },
    });
    try std.testing.expectEqualDeep(&expected, got.segments.items);
}

test "Contour.close, co-linear" {
    const alloc = std.testing.allocator;
    var got: Contour = try .init(alloc, .{ .x = 10, .y = 10 }, .{ .x = 20, .y = 20 });
    defer got.deinit(alloc);
    try got.plot(alloc, .{ .x = 10, .y = 20 });
    try got.plot(alloc, .{ .x = 20, .y = 10 });
    try got.plot(alloc, .{ .x = 15, .y = 10 });
    try got.close(alloc);
    try std.testing.expectEqual(true, got.closed);
    const expected = mkExpectedSegment(&[_]MkExpectedSegmentOpts{
        .{
            .p0 = .{ .x = 10, .y = 10 },
            .p1 = .{ .x = 20, .y = 20 },
            .orientation = .ccw,
        },
        .{
            .p0 = .{ .x = 20, .y = 20 },
            .p1 = .{ .x = 10, .y = 20 },
            .orientation = .cw,
        },
        .{
            .p0 = .{ .x = 10, .y = 20 },
            .p1 = .{ .x = 20, .y = 10 },
            .orientation = .cw,
        },
        .{
            .p0 = .{ .x = 20, .y = 10 },
            .p1 = .{ .x = 10, .y = 10 },
            .orientation = .ccw,
        },
    });
    try std.testing.expectEqualDeep(&expected, got.segments.items);
}

test "Contour.alignSegments" {
    const star = [_]Point{
        .{ .x = 25, .y = 5 },
        .{ .x = 32, .y = 25 },
        .{ .x = 15, .y = 13 },
        .{ .x = 35, .y = 13 },
        .{ .x = 18, .y = 25 },
    };

    const alloc = std.testing.allocator;
    var got: Contour = try .init(alloc, star[0], star[1]);
    defer got.deinit(alloc);
    for (star[2..]) |pt| {
        try got.plot(alloc, pt);
    }
    try got.close(alloc);

    got.alignSegments();
    const expected = mkExpectedSegment(&[_]MkExpectedSegmentOpts{
        .{
            .p0 = .{ .x = 15, .y = 13 },
            .p1 = .{ .x = 35, .y = 13 },
            .orientation = .cw,
        },
        .{
            .p0 = .{ .x = 35, .y = 13 },
            .p1 = .{ .x = 18, .y = 25 },
            .orientation = .cw,
        },
        .{
            .p0 = .{ .x = 18, .y = 25 },
            .p1 = .{ .x = 25, .y = 5 },
            .orientation = .cw,
        },
        .{
            .p0 = .{ .x = 25, .y = 5 },
            .p1 = .{ .x = 32, .y = 25 },
            .orientation = .cw,
        },
        .{
            .p0 = .{ .x = 32, .y = 25 },
            .p1 = .{ .x = 15, .y = 13 },
            .orientation = .cw,
        },
    });
    try std.testing.expectEqualDeep(&expected, got.segments.items);
}

test "Contour.computeIntersections" {
    const star = [_]Point{
        .{ .x = 25, .y = 5 },
        .{ .x = 32, .y = 25 },
        .{ .x = 15, .y = 13 },
        .{ .x = 35, .y = 13 },
        .{ .x = 18, .y = 25 },
    };

    const alloc = std.testing.allocator;
    var got: Contour = try .init(alloc, star[0], star[1]);
    defer got.deinit(alloc);
    for (star[2..]) |pt| {
        try got.plot(alloc, pt);
    }
    try got.close(alloc);

    try got.computeIntersections(alloc);
    // These values were generated by just dumping the result using
    // std.debug.print, and adding some necessary formatting.
    const expected = [_][2]Contour.Segment.Intersection{
        .{
            .{
                .id = 0,
                .t = 0.4,
                .out_idx = 2,
                .point = .{ .x = 27.8, .y = 13 },
                .orientation = .ccw,
            },
            .{
                .id = 1,
                .t = 0.6037735849056604,
                .out_idx = 3,
                .point = .{ .x = 29.22641509433962, .y = 17.075471698113205 },
                .orientation = .cw,
            },
        },
        .{
            .{
                .id = 2,
                .t = 0.4117647058823529,
                .out_idx = 3,
                .point = .{ .x = 25, .y = 20.058823529411764 },
                .orientation = .ccw,
            },
            .{
                .id = 3,
                .t = 0.660377358490566,
                .out_idx = 4,
                .point = .{ .x = 20.77358490566038, .y = 17.07547169811321 },
                .orientation = .cw,
            },
        },
        .{
            .{
                .id = 4,
                .t = 0.36,
                .out_idx = 4,
                .point = .{ .x = 22.2, .y = 13 },
                .orientation = .ccw,
            },
            .{
                .id = 0,
                .t = 0.64,
                .out_idx = 0,
                .point = .{ .x = 27.8, .y = 13 },
                .orientation = .cw,
            },
        },
        .{
            .{
                .id = 1,
                .t = 0.33962264150943394,
                .out_idx = 0,
                .point = .{ .x = 29.22641509433962, .y = 17.075471698113205 },
                .orientation = .ccw,
            },
            .{
                .id = 2,
                .t = 0.5882352941176471,
                .out_idx = 1,
                .point = .{ .x = 25, .y = 20.058823529411764 },
                .orientation = .cw,
            },
        },
        .{
            .{
                .id = 3,
                .t = 0.39622641509433965,
                .out_idx = 1,
                .point = .{ .x = 20.77358490566038, .y = 17.07547169811321 },
                .orientation = .ccw,
            },
            .{
                .id = 4,
                .t = 0.6,
                .out_idx = 2,
                .point = .{ .x = 22.2, .y = 13 },
                .orientation = .cw,
            },
        },
    };

    for (got.segments.items, 0..) |seg, idx| {
        try std.testing.expectEqualDeep(&expected[idx], seg.intersections.items);
    }
}

test "Contour.Segment.insertIntersection" {
    const alloc = std.testing.allocator;
    var got: Contour.Segment = .init(.{ .x = 10, .y = 10 }, .{ .x = 20, .y = 20 });
    defer got.deinit(alloc);
    try got.insertIntersection(
        alloc,
        .{
            .id = 0,
            .t = 0.5,
            .out_idx = 3,
            .point = .{ .x = 15, .y = 15 },
            .orientation = .cw,
        },
    );
    try got.insertIntersection(
        alloc,
        .{
            .id = 1,
            .t = 0.25,
            .out_idx = 5,
            .point = .{ .x = 12.5, .y = 12.5 },
            .orientation = .cw,
        },
    );
    try got.insertIntersection(
        alloc,
        .{
            .id = 2,
            .t = 0.75,
            .out_idx = 5,
            .point = .{ .x = 17.5, .y = 17.5 },
            .orientation = .cw,
        },
    );

    const expected = [_]Contour.Segment.Intersection{
        .{
            .id = 1,
            .t = 0.25,
            .out_idx = 5,
            .point = .{ .x = 12.5, .y = 12.5 },
            .orientation = .cw,
        },
        .{
            .id = 0,
            .t = 0.5,
            .out_idx = 3,
            .point = .{ .x = 15, .y = 15 },
            .orientation = .cw,
        },
        .{
            .id = 2,
            .t = 0.75,
            .out_idx = 5,
            .point = .{ .x = 17.5, .y = 17.5 },
            .orientation = .cw,
        },
    };
    try std.testing.expectEqualDeep(&expected, got.intersections.items);
}

test "Contour.Segment.unshiftIntersection" {
    const alloc = std.testing.allocator;
    var got: Contour.Segment = .init(.{ .x = 10, .y = 10 }, .{ .x = 20, .y = 20 });
    defer got.deinit(alloc);
    try got.insertIntersection(
        alloc,
        .{
            .id = 0,
            .t = 0.5,
            .out_idx = 3,
            .point = .{ .x = 15, .y = 15 },
            .orientation = .cw,
        },
    );
    try got.insertIntersection(
        alloc,
        .{
            .id = 1,
            .t = 0.25,
            .out_idx = 5,
            .point = .{ .x = 12.5, .y = 12.5 },
            .orientation = .cw,
        },
    );
    try got.insertIntersection(
        alloc,
        .{
            .id = 2,
            .t = 0.75,
            .out_idx = 5,
            .point = .{ .x = 17.5, .y = 17.5 },
            .orientation = .cw,
        },
    );

    const expected = [_]Contour.Segment.Intersection{
        .{
            .id = 1,
            .t = 0.25,
            .out_idx = 5,
            .point = .{ .x = 12.5, .y = 12.5 },
            .orientation = .cw,
        },
        .{
            .id = 0,
            .t = 0.5,
            .out_idx = 3,
            .point = .{ .x = 15, .y = 15 },
            .orientation = .cw,
        },
        .{
            .id = 2,
            .t = 0.75,
            .out_idx = 5,
            .point = .{ .x = 17.5, .y = 17.5 },
            .orientation = .cw,
        },
    };

    for (0..expected.len) |idx| {
        try std.testing.expectEqualDeep(expected[idx], got.unshiftIntersection());
    }

    try std.testing.expectEqual(null, got.unshiftIntersection());
}

test "Contour.Segment.intersectionFor" {
    {
        const in: Contour.Segment = .init(.{ .x = 10, .y = 10 }, .{ .x = 20, .y = 20 });
        const out: Contour.Segment = .init(.{ .x = 20, .y = 15 }, .{ .x = 15, .y = 20 });

        const expected: Contour.Segment.IntersectionForResult = .{
            .in_t = 0.75,
            .out_t = 0.5,
            .point = .{ .x = 17.5, .y = 17.5 },
            .clockwise = true,
        };

        try std.testing.expectEqualDeep(expected, Contour.Segment.intersectionFor(in, out));
    }

    {
        // Co-linear
        const in: Contour.Segment = .init(.{ .x = 10, .y = 10 }, .{ .x = 20, .y = 20 });
        const out: Contour.Segment = .init(.{ .x = 15, .y = 15 }, .{ .x = 25, .y = 25 });
        try std.testing.expectEqual(null, Contour.Segment.intersectionFor(in, out));
    }

    {
        // OOB y (t1 out of range)
        const in: Contour.Segment = .init(.{ .x = 10, .y = 10 }, .{ .x = 20, .y = 20 });
        const out: Contour.Segment = .init(.{ .x = 20, .y = 25 }, .{ .x = 10, .y = 35 });
        try std.testing.expectEqual(null, Contour.Segment.intersectionFor(in, out));
    }

    {
        // OOB x (t2 out of range)
        const in: Contour.Segment = .init(.{ .x = 10, .y = 10 }, .{ .x = 20, .y = 20 });
        const out: Contour.Segment = .init(.{ .x = 10, .y = 15 }, .{ .x = 5, .y = 20 });
        try std.testing.expectEqual(null, Contour.Segment.intersectionFor(in, out));
    }
}

const MkExpectedSegmentOpts = struct {
    p0: Point,
    p1: Point,
    orientation: Contour.Segment.Orientation,
};

/// For testing only.
fn mkExpectedSegment(comptime in: []const MkExpectedSegmentOpts) [in.len]Contour.Segment {
    var result: [in.len]Contour.Segment = undefined;
    for (in, 0..) |elem, idx| {
        var seg = Contour.Segment.init(elem.p0, elem.p1);
        seg.orientation = elem.orientation;
        result[idx] = seg;
    }

    return result;
}
