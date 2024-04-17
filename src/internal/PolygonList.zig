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

pub fn edgesForY(
    self: *const PolygonList,
    alloc: mem.Allocator,
    line_y: f64,
    fill_rule: FillRule,
) !std.ArrayList(i32) {
    var edge_list = std.ArrayList(Polygon.Edge).init(alloc);
    defer edge_list.deinit();

    for (self.polygons.items) |poly| {
        var poly_edge_list = try poly.edgesForY(alloc, line_y);
        defer poly_edge_list.deinit();
        try edge_list.appendSlice(poly_edge_list.items);
    }

    const edge_list_sorted = try edge_list.toOwnedSlice();
    mem.sort(Polygon.Edge, edge_list_sorted, {}, Polygon.Edge.sort_asc);
    defer alloc.free(edge_list_sorted);

    // We need to now process our edge list, particularly in the case of
    // non-zero fill rules.
    //
    // TODO: This could probably be optimized by simply returning the edge
    // list directly and having the filler work off of that, which would
    // remove the need to O(N) copy the edge X-coordinates for even-odd.
    // Conversely, orderedRemove in an ArrayList is O(N) and would need to
    // be run each time an edge needs to be removed during non-zero rule
    // processing. Currently, at the very least, we pre-allocate capacity
    // to the incoming sorted edge list.
    var final_edge_list = try std.ArrayList(i32).initCapacity(alloc, edge_list_sorted.len);
    errdefer final_edge_list.deinit();
    var winding_number: i32 = 0;
    var start: i32 = undefined;
    if (fill_rule == .even_odd) {
        // Just copy all of our edges - the outer filler fills by
        // even-odd rule naively, so this is the correct set for that
        // method.
        for (edge_list_sorted) |e| {
            try final_edge_list.append(e.x);
        }
    } else {
        // Go through our edges and filter based on the winding number.
        for (edge_list_sorted) |e| {
            if (winding_number == 0) {
                start = e.x;
            }
            winding_number += @intCast(e.dir);
            if (winding_number == 0) {
                try final_edge_list.append(start);
                try final_edge_list.append(e.x);
            }
        }
    }

    return final_edge_list;
}
