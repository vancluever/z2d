// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024-2025 Chris Marchesi

//! A polygon plotter for fill operations.
const std = @import("std");
const debug = @import("std").debug;
const mem = @import("std").mem;
const testing = @import("std").testing;

const nodepkg = @import("path_nodes.zig");

const Polygon = @import("Polygon.zig");
const Point = @import("Point.zig");
const Spline = @import("Spline.zig");
const PlotterVTable = @import("PlotterVTable.zig");
const InternalError = @import("InternalError.zig").InternalError;
const PointBuffer = @import("util.zig").PointBuffer(1, 3);

pub const Error = InternalError || mem.Allocator.Error;

pub fn plot(
    alloc: mem.Allocator,
    nodes: []const nodepkg.PathNode,
    scale: f64,
    tolerance: f64,
) Error!Polygon {
    var result: Polygon = .{ .scale = scale };
    errdefer result.deinit(alloc);

    var points: PointBuffer = .{};

    for (nodes, 0..) |node, i| {
        switch (node) {
            .move_to => |n| {
                // Check if this is the last node, and no-op if it is, as this
                // is the auto-added move_to node that is given after
                // close_path.
                if (i == nodes.len - 1) {
                    break;
                }
                points.reset();
                points.add(n.point);
            },
            .line_to => |n| {
                if (points.last()) |last_point| {
                    if (!last_point.equal(n.point)) {
                        try result.addEdge(alloc, last_point, n.point);
                        points.add(n.point);
                    }
                } else return InternalError.InvalidState;
            },
            .curve_to => |n| {
                if (points.len == 0) return InternalError.InvalidState;
                var ctx: SplinePlotterCtx = .{
                    .polygon = &result,
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
                // Only proceed if we have 3 points in the buffer; anything
                // else is a degenerate line (e.g., move_to -> line_to (2) or
                // move_to -> close_path (1)). These scenarios will be cleared
                // on the next move_to (which happens right after this).
                //
                // Note on the move_to -> line_to scenario, an edge will be
                // generated. While this will produce a broken image, it should
                // be fine as far as rasterization goes, as the rasterizer
                // works on edge pairs, with trailing odd edges discarded.
                if (points.len >= 3) {
                    // No-op if our initial and current points are equal
                    if (points.last().?.equal(points.first().?)) continue;

                    // Plot from the current point to the initial point
                    try result.addEdge(alloc, points.last().?, points.first().?);

                    // Set the current point to the initial point.
                    points.add(points.first().?);
                }
            },
        }
    }

    return result;
}

const SplinePlotterCtx = struct {
    polygon: *Polygon,
    points: *PointBuffer,
    alloc: mem.Allocator,

    fn line_to(ctx: *anyopaque, err_: *?PlotterVTable.Error, node: nodepkg.PathLineTo) void {
        const self: *SplinePlotterCtx = @ptrCast(@alignCast(ctx));
        if (self.points.last()) |last_point| {
            if (!last_point.equal(node.point)) {
                self.polygon.addEdge(self.alloc, last_point, node.point) catch |err| {
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

test "degenerate line_to" {
    const alloc = testing.allocator;
    var nodes: std.ArrayListUnmanaged(nodepkg.PathNode) = .{};
    defer nodes.deinit(alloc);
    try nodes.append(alloc, .{ .move_to = .{ .point = .{ .x = 5, .y = 0 } } });
    try nodes.append(alloc, .{ .line_to = .{ .point = .{ .x = 10, .y = 10 } } });
    try nodes.append(alloc, .{ .line_to = .{ .point = .{ .x = 10, .y = 10 } } });
    try nodes.append(alloc, .{ .line_to = .{ .point = .{ .x = 0, .y = 10 } } });
    try nodes.append(alloc, .{ .close_path = .{} });
    try nodes.append(alloc, .{ .move_to = .{ .point = .{ .x = 5, .y = 0 } } });

    var result = try plot(alloc, nodes.items, 1, 1);
    defer result.deinit(alloc);
    // NOTE: only 2 edges should be here as there is a horizontal edge
    // ((10,10) -> (0, 10)), this is now filtered out.
    try testing.expectEqual(2, result.edges.items.len);
    try testing.expectEqualSlices(Polygon.Edge, &.{
        .{
            .y0 = 0.0,
            .y1 = 10.0,
            .x_start = 5.0,
            .x_inc = 0.5,
        },
        .{
            .y0 = 10.0,
            .y1 = 0.0,
            .x_start = 5.0,
            .x_inc = -0.5,
        },
    }, result.edges.items);
}

test "degenerate close" {
    {
        // move_to -> line_to
        const alloc = testing.allocator;
        var nodes: std.ArrayListUnmanaged(nodepkg.PathNode) = .{};
        defer nodes.deinit(alloc);
        try nodes.append(alloc, .{ .move_to = .{ .point = .{ .x = 5, .y = 0 } } });
        try nodes.append(alloc, .{ .line_to = .{ .point = .{ .x = 10, .y = 10 } } });
        try nodes.append(alloc, .{ .close_path = .{} });
        try nodes.append(alloc, .{ .move_to = .{ .point = .{ .x = 5, .y = 0 } } });

        var result = try plot(alloc, nodes.items, 1, 1);
        defer result.deinit(alloc);
        try testing.expectEqual(1, result.edges.items.len);
        try testing.expectEqualSlices(Polygon.Edge, &.{
            .{
                .y0 = 0.0,
                .y1 = 10.0,
                .x_start = 5.0,
                .x_inc = 0.5,
            },
        }, result.edges.items);
    }
    {
        // double close
        const alloc = testing.allocator;
        var nodes: std.ArrayListUnmanaged(nodepkg.PathNode) = .{};
        defer nodes.deinit(alloc);
        try nodes.append(alloc, .{ .move_to = .{ .point = .{ .x = 5, .y = 0 } } });
        try nodes.append(alloc, .{ .line_to = .{ .point = .{ .x = 10, .y = 10 } } });
        try nodes.append(alloc, .{ .line_to = .{ .point = .{ .x = 0, .y = 10 } } });
        try nodes.append(alloc, .{ .close_path = .{} });
        try nodes.append(alloc, .{ .move_to = .{ .point = .{ .x = 5, .y = 0 } } });
        try nodes.append(alloc, .{ .close_path = .{} });
        try nodes.append(alloc, .{ .move_to = .{ .point = .{ .x = 5, .y = 0 } } });

        var result = try plot(alloc, nodes.items, 1, 1);
        defer result.deinit(alloc);
        // NOTE: only 2 edges should be here as there is a horizontal edge
        // ((10,10) -> (0, 10)), this is now filtered out.
        try testing.expectEqual(2, result.edges.items.len);
        try testing.expectEqualSlices(Polygon.Edge, &.{
            .{
                .y0 = 0.0,
                .y1 = 10.0,
                .x_start = 5.0,
                .x_inc = 0.5,
            },
            .{
                .y0 = 10.0,
                .y1 = 0.0,
                .x_start = 5.0,
                .x_inc = -0.5,
            },
        }, result.edges.items);
    }
}
