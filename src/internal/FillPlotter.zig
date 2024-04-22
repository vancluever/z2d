// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024 Chris Marchesi

//! A polygon plotter for fill operations.
const std = @import("std");
const debug = @import("std").debug;
const mem = @import("std").mem;

// const options = @import("../options.zig");
const nodepkg = @import("path_nodes.zig");

const Polygon = @import("Polygon.zig");
const PolygonList = @import("PolygonList.zig");
const Point = @import("Point.zig");
const Spline = @import("Spline.zig");
const InternalError = @import("../errors.zig").InternalError;

pub fn plot(
    alloc: mem.Allocator,
    nodes: std.ArrayList(nodepkg.PathNode),
    scale: f64,
    tolerance: f64,
) !PolygonList {
    var result = PolygonList.init(alloc);
    errdefer result.deinit();

    var initial_point: ?Point = null;
    var current_point: ?Point = null;
    var current_polygon: ?Polygon = null;

    for (nodes.items, 0..) |node, i| {
        switch (node) {
            .move_to => |n| {
                if (current_polygon) |poly| try result.append(poly);

                // Check if this is the last node, and no-op if it is, as this
                // is the auto-added move_to node that is given after
                // close_path.
                if (i == nodes.items.len - 1) {
                    break;
                }

                current_polygon = Polygon.init(alloc, scale);
                try current_polygon.?.plot(n.point, null);
                initial_point = n.point;
                current_point = n.point;
            },
            .line_to => |n| {
                if (initial_point == null) return InternalError.InvalidState;
                if (current_point == null) return InternalError.InvalidState;
                if (current_polygon == null) return InternalError.InvalidState;

                try current_polygon.?.plot(n.point, null);
                current_point = n.point;
            },
            .curve_to => |n| {
                if (initial_point == null) return InternalError.InvalidState;
                if (current_point == null) return InternalError.InvalidState;
                if (current_polygon == null) return InternalError.InvalidState;

                var ctx: SplinePlotterCtx = .{
                    .polygon = &current_polygon.?,
                    .current_point = &current_point,
                };
                var spline: Spline = .{
                    .a = current_point.?,
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
                if (initial_point == null) return InternalError.InvalidState;
                if (current_point == null) return InternalError.InvalidState;
                if (current_polygon == null) return InternalError.InvalidState;

                // No-op if our initial and current points are equal
                if (current_point.?.equal(initial_point.?)) continue;

                // Set the current point to the initial point.
                current_point = initial_point;
            },
        }
    }

    return result;
}

const SplinePlotterCtx = struct {
    polygon: *Polygon,
    current_point: *?Point,

    fn line_to(ctx: *anyopaque, err_: *?anyerror, node: nodepkg.PathLineTo) void {
        const self: *SplinePlotterCtx = @ptrCast(@alignCast(ctx));
        self.polygon.plot(node.point, null) catch |err| {
            err_.* = err;
            return;
        };
        self.current_point.* = node.point;
    }
};
