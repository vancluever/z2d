// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024 Chris Marchesi

//! Represents a list of LinkedPolygons, intended for multiple subpath
//! operations.
const PolygonList = @This();

const std = @import("std");
const debug = @import("std").debug;
const math = @import("std").math;
const mem = @import("std").mem;

const FillRule = @import("../options.zig").FillRule;
const Polygon = @import("Polygon.zig");
const Point = @import("Point.zig");

polygons: std.ArrayList(Polygon),
start: Point = .{ .x = 0, .y = 0 },
end: Point = .{ .x = 0, .y = 0 },

pub fn init(alloc: mem.Allocator) PolygonList {
    return .{
        .polygons = std.ArrayList(Polygon).init(alloc),
    };
}

pub fn deinit(self: *PolygonList) void {
    for (self.polygons.items) |poly| poly.deinit();
    self.polygons.deinit();
}

pub fn append(self: *PolygonList, poly: Polygon) !void {
    const first = self.polygons.items.len == 0;

    try self.polygons.append(poly);

    if (first) {
        self.start = poly.start;
        self.end = poly.end;
    } else {
        if (self.start.x > poly.start.x) self.start.x = poly.start.x;
        if (self.start.y > poly.start.y) self.start.y = poly.start.y;
        if (self.end.x < poly.end.x) self.end.x = poly.end.x;
        if (self.end.y < poly.end.y) self.end.y = poly.end.y;
    }
}

pub const EdgeListIterator = struct {
    index: usize = 0,
    edges: []Polygon.Edge,
    fill_rule: FillRule,

    pub const EdgePair = struct {
        start: i32,
        end: i32,
    };

    pub fn next(it: *EdgeListIterator) ?EdgePair {
        debug.assert(it.index <= it.edges.len);
        if (it.edges.len == 0 or it.index >= it.edges.len - 1) return null;
        if (it.fill_rule == .even_odd) {
            const start = it.edges[it.index].x;
            const end = it.edges[it.index + 1].x;
            it.index += 2;
            return .{
                .start = start,
                .end = end,
            };
        } else {
            var winding_number: i32 = 0;
            var start: i32 = undefined;
            while (it.index < it.edges.len) : (it.index += 1) {
                if (winding_number == 0) {
                    start = it.edges[it.index].x;
                }
                winding_number += @intCast(it.edges[it.index].dir);
                if (winding_number == 0) {
                    const end = it.edges[it.index].x;
                    it.index += 1;
                    return .{
                        .start = start,
                        .end = end,
                    };
                }
            }
        }

        return null;
    }
};

/// WARNING: Caller is expected to free the edges returned here manually
/// somehow
pub fn edgesForY(
    self: *const PolygonList,
    alloc: mem.Allocator,
    line_y: f64,
    fill_rule: FillRule,
) !EdgeListIterator {
    var edge_list = std.ArrayList(Polygon.Edge).init(alloc);
    defer edge_list.deinit();

    for (self.polygons.items) |poly| {
        var poly_edge_list = try poly.edgesForY(alloc, line_y);
        defer poly_edge_list.deinit();
        try edge_list.appendSlice(poly_edge_list.items);
    }

    const edge_list_sorted = try edge_list.toOwnedSlice();
    mem.sort(Polygon.Edge, edge_list_sorted, {}, Polygon.Edge.sort_asc);
    return .{
        .edges = edge_list_sorted,
        .fill_rule = fill_rule,
    };
}
