// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024-2025 Chris Marchesi

//! A polyline plotter, converts a path to a Contour (not a Polygon).
//!
//! This is a variation of our fill plotter, as the logic is pretty much the
//! same, with the general exception of we need to keep less state (as we are
//! plotting a polyline, not edges), and the path can be open, not just
//! closed.
const std = @import("std");
const debug = @import("std").debug;
const mem = @import("std").mem;
const testing = @import("std").testing;

const nodepkg = @import("../path_nodes.zig");

const Point = @import("../Point.zig");
const PlotterVTable = @import("PlotterVTable.zig");
const PointBuffer = @import("point_buffer.zig").PointBuffer(1, 2);
const Contour = @import("Polygon.zig").Contour;
const Spline = @import("Spline.zig");

const InternalError = @import("../InternalError.zig").InternalError;
pub const Error = InternalError || mem.Allocator.Error;

pub fn plot(
    alloc: mem.Allocator,
    nodes: []const nodepkg.PathNode,
    tolerance: f64,
) Error!Contour.List {
    var result: Contour.List = .empty;
    errdefer result.deinit(alloc);
    var current_contour: Contour = .{ .scale = 1.0 };

    var points: PointBuffer = .{};

    for (nodes, 0..) |node, i| {
        switch (node) {
            .move_to => |n| {
                // Add last contour if there were nodes in it
                if (current_contour.len != 0) {
                    try result.append(alloc, current_contour);
                    current_contour = .{ .scale = 1.0 };
                }
                points.reset();
                // Check if this is the last node, and no-op if it is, as this
                // is the auto-added move_to node that is given after
                // close_path.
                if (i == nodes.len - 1) {
                    break;
                }
                try current_contour.plot(alloc, n.point, null);
                points.add(n.point);
            },
            .line_to => |n| {
                if (points.last()) |last_point| {
                    if (!last_point.equal(n.point)) {
                        try current_contour.plot(alloc, n.point, null);
                        points.add(n.point);
                    }
                } else return InternalError.InvalidState;
            },
            .curve_to => |n| {
                if (points.len == 0) return InternalError.InvalidState;
                var ctx: SplinePlotterCtx = .{
                    .contour = &current_contour,
                    .points = &points,
                    .alloc = alloc,
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
                if (points.len >= 2) {
                    // No-op if our initial and current points are equal
                    if (points.last().?.equal(points.first().?)) continue;

                    // Plot from the current point to the initial point
                    try current_contour.plot(alloc, points.first().?, null);

                    // Set the current point to the initial point.
                    points.add(points.first().?);
                }
            },
        }
    }

    // Add last contour if there were nodes in it
    if (current_contour.len != 0) {
        try result.append(alloc, current_contour);
    }

    return result;
}

const SplinePlotterCtx = struct {
    contour: *Contour,
    points: *PointBuffer,
    alloc: mem.Allocator,

    fn line_to(ctx: *anyopaque, err_: *?PlotterVTable.Error, node: nodepkg.PathLineTo) void {
        const self: *SplinePlotterCtx = @ptrCast(@alignCast(ctx));
        if (self.points.last()) |last_point| {
            if (!last_point.equal(node.point)) {
                self.contour.plot(self.alloc, node.point, null) catch |err| {
                    err_.* = err;
                    return;
                };
                self.points.add(node.point);
            }
        } else {
            err_.* = InternalError.InvalidState;
            return;
        }
    }
};
