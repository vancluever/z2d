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
const edge_buffer_size = @import("../painter.zig").edge_buffer_size;

polygons: std.SinglyLinkedList(Polygon) = .{},
start: Point = .{ .x = 0, .y = 0 },
end: Point = .{ .x = 0, .y = 0 },

pub fn deinit(self: *PolygonList, alloc: mem.Allocator) void {
    var poly_ = self.polygons.first;
    while (poly_) |poly| {
        poly_ = poly.next;
        poly.data.deinit(alloc);
        alloc.destroy(poly);
    }
    self.polygons = .{};
}

pub fn prepend(self: *PolygonList, alloc: mem.Allocator, poly: Polygon) mem.Allocator.Error!void {
    const first = self.polygons.len() == 0;

    const n = try alloc.create(std.SinglyLinkedList(Polygon).Node);
    n.data = poly;
    self.polygons.prepend(n);

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

    pub fn deinit(it: *EdgeListIterator, alloc: mem.Allocator) void {
        alloc.free(it.edges);
        it.edges = undefined;
    }

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
) Polygon.EdgesForYError!EdgeListIterator {
    // Internal implementation note: we work off of a small (512 byte) FBA with
    // the heap as a fallback. FBAs are stacked in that if a freed allocation
    // is the last one allocated, memory will be recovered, but if not, it's
    // just dropped on the floor and that memory is "orphaned", if you will. As
    // such, to be effective, we want to make sure that the space is divided up
    // well between the final edge list and the temporary edge list, as such we
    // give the final edge list (which lives at the bottom of the FBA stack)
    // 2/3 of the space as initial capacity, to reduce the likelihood of
    // wasteful resizes given that an initial ArrayList size is only 8 items.
    const edge_list_capacity = edge_buffer_size / @sizeOf(Polygon.Edge) / 3 * 2;
    var edge_list = try std.ArrayListUnmanaged(Polygon.Edge).initCapacity(alloc, edge_list_capacity);
    defer edge_list.deinit(alloc);

    var poly_ = self.polygons.first;
    while (poly_) |poly| : (poly_ = poly.next) {
        var poly_edge_list = try poly.data.edgesForY(alloc, line_y);
        defer poly_edge_list.deinit(alloc);
        try edge_list.appendSlice(alloc, poly_edge_list.items);
    }

    const edge_list_sorted = try edge_list.toOwnedSlice(alloc);
    mem.sort(Polygon.Edge, edge_list_sorted, {}, Polygon.Edge.sort_asc);
    return .{
        .edges = edge_list_sorted,
        .fill_rule = fill_rule,
    };
}
