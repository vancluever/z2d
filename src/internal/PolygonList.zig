// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024-2025 Chris Marchesi

//! Represents a list of LinkedPolygons, intended for multiple subpath
//! operations.
const PolygonList = @This();

const std = @import("std");
const debug = @import("std").debug;
const math = @import("std").math;
const mem = @import("std").mem;
const testing = @import("std").testing;

const FillRule = @import("../options.zig").FillRule;
const Polygon = @import("Polygon.zig");
const Point = @import("Point.zig");
const edge_buffer_size = @import("../painter.zig").edge_buffer_size;

const runCases = @import("util.zig").runCases;
const TestingError = @import("util.zig").TestingError;

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

/// Returns true if our polygon list is somewhere within the box starting at
/// (0,0) with the width box_width and the height box_height. Used to check if
/// we should actually proceed with drawing.
pub fn inBox(self: *const PolygonList, scale: f64, box_width: i32, box_height: i32) bool {
    if (!math.isFinite(self.start.x) or !math.isFinite(self.start.y) or
        !math.isFinite(self.end.x) or !math.isFinite(self.end.y))
    {
        @panic("invalid polygon dimensions. this is a bug, please report it");
    }

    if (!math.isFinite(scale) or scale < 1.0) {
        @panic("invalid value for scale. this is a bug, please report it");
    }

    if (box_width < 1 or box_height < 1) {
        @panic("invalid box width or height. this is a bug, please report it");
    }

    // Round our polygon to the appropriate dimensions. For scanline fill, we
    // make sure to push our our box so the whole of the polygon fits in
    // the box.
    const poly_start_x: i32 = @intFromFloat(@floor(self.start.x / scale));
    const poly_start_y: i32 = @intFromFloat(@floor(self.start.y / scale));
    const poly_end_x: i32 = @intFromFloat(@ceil(self.end.x / scale));
    const poly_end_y: i32 = @intFromFloat(@ceil(self.end.y / scale));

    // Our polygon width and height
    const poly_width: i32 = poly_end_x - poly_start_x;
    const poly_height: i32 = poly_end_y - poly_start_y;

    // If this happens, there's an error in our polygon plotting.
    if (poly_width < 0 or poly_height < 0) {
        @panic("negative polygon width or height. this is a bug, please report it");
    }

    // If one of our width or height are zero, nothing drawable was
    // ultimately plotted, possibly a degenerate case.
    if (poly_width == 0 or poly_height == 0) {
        return false;
    }

    // Check the upper-left of our drawing area to make sure, that in the case
    // of negative start offsets, we actually reach into the surface. If we
    // don't (i.e., if it's not wide or high enough), we're not in the box.
    if (poly_start_x + poly_width < 0 or poly_start_y + poly_height < 0) {
        return false;
    }

    // Finally, if our start co-ordinates are outside the right or upper
    // bounds of the surface, we're not in the box.
    if (poly_start_x >= box_width or poly_start_y >= box_height) {
        return false;
    }

    // We're in the box.
    return true;
}

test "PolygonList.inBox" {
    const name = "PolygonList.inBox";
    const cases = [_]struct {
        name: []const u8,
        polygon_list: PolygonList,
        scale: f64,
        box_width: i32,
        box_height: i32,
        expected: bool,
    }{
        .{
            .name = "basic",
            .polygon_list = .{ .start = .{ .x = 10.0, .y = 10.0 }, .end = .{ .x = 20.0, .y = 20.0 } },
            .scale = 1.0,
            .box_height = 30,
            .box_width = 30,
            .expected = true,
        },
        .{
            .name = "overlap, upper",
            .polygon_list = .{ .start = .{ .x = 2.5, .y = -5.0 }, .end = .{ .x = 7.5, .y = 5.0 } },
            .scale = 1.0,
            .box_height = 10,
            .box_width = 10,
            .expected = true,
        },
        .{
            .name = "overlap, lower",
            .polygon_list = .{ .start = .{ .x = 2.5, .y = 5.0 }, .end = .{ .x = 7.5, .y = 15.0 } },
            .scale = 1.0,
            .box_height = 10,
            .box_width = 10,
            .expected = true,
        },
        .{
            .name = "overlap, left",
            .polygon_list = .{ .start = .{ .x = -5.0, .y = 2.5 }, .end = .{ .x = 5.0, .y = 7.5 } },
            .scale = 1.0,
            .box_height = 10,
            .box_width = 10,
            .expected = true,
        },
        .{
            .name = "overlap, right",
            .polygon_list = .{ .start = .{ .x = 5.0, .y = 2.5 }, .end = .{ .x = 15.0, .y = 7.5 } },
            .scale = 1.0,
            .box_height = 10,
            .box_width = 10,
            .expected = true,
        },
        .{
            .name = "overlap, upper left",
            .polygon_list = .{ .start = .{ .x = -5.0, .y = -5.0 }, .end = .{ .x = 5.0, .y = 5.0 } },
            .scale = 1.0,
            .box_height = 10,
            .box_width = 10,
            .expected = true,
        },
        .{
            .name = "overlap, upper right",
            .polygon_list = .{ .start = .{ .x = 5.0, .y = -5.0 }, .end = .{ .x = 15.0, .y = 5.0 } },
            .scale = 1.0,
            .box_height = 10,
            .box_width = 10,
            .expected = true,
        },
        .{
            .name = "overlap, lower left",
            .polygon_list = .{ .start = .{ .x = -5.0, .y = 5.0 }, .end = .{ .x = 5.0, .y = 15.0 } },
            .scale = 1.0,
            .box_height = 10,
            .box_width = 10,
            .expected = true,
        },
        .{
            .name = "overlap, lower right",
            .polygon_list = .{ .start = .{ .x = 5.0, .y = 5.0 }, .end = .{ .x = 15.0, .y = 15.0 } },
            .scale = 1.0,
            .box_height = 10,
            .box_width = 10,
            .expected = true,
        },
        .{
            .name = "OOB, upper",
            .polygon_list = .{ .start = .{ .x = 2.5, .y = -15.0 }, .end = .{ .x = 7.5, .y = -5.0 } },
            .scale = 1.0,
            .box_height = 10,
            .box_width = 10,
            .expected = false,
        },
        .{
            .name = "OOB, lower",
            .polygon_list = .{ .start = .{ .x = 2.5, .y = 15.0 }, .end = .{ .x = 7.5, .y = 25.0 } },
            .scale = 1.0,
            .box_height = 10,
            .box_width = 10,
            .expected = false,
        },
        .{
            .name = "OOB, left",
            .polygon_list = .{ .start = .{ .x = -15.0, .y = 2.5 }, .end = .{ .x = -5.0, .y = 7.5 } },
            .scale = 1.0,
            .box_height = 10,
            .box_width = 10,
            .expected = false,
        },
        .{
            .name = "OOB, right",
            .polygon_list = .{ .start = .{ .x = 15.0, .y = 2.5 }, .end = .{ .x = 25.0, .y = 7.5 } },
            .scale = 1.0,
            .box_height = 10,
            .box_width = 10,
            .expected = false,
        },
        .{
            .name = "OOB, upper left",
            .polygon_list = .{ .start = .{ .x = -20.0, .y = -20.0 }, .end = .{ .x = -10.0, .y = -10.0 } },
            .scale = 1.0,
            .box_height = 10,
            .box_width = 10,
            .expected = false,
        },
        .{
            .name = "OOB, upper right",
            .polygon_list = .{ .start = .{ .x = 20.0, .y = -20.0 }, .end = .{ .x = 30.0, .y = -10.0 } },
            .scale = 1.0,
            .box_height = 10,
            .box_width = 10,
            .expected = false,
        },
        .{
            .name = "OOB, lower left",
            .polygon_list = .{ .start = .{ .x = -20.0, .y = 20.0 }, .end = .{ .x = -10.0, .y = 30.0 } },
            .scale = 1.0,
            .box_height = 10,
            .box_width = 10,
            .expected = false,
        },
        .{
            .name = "OOB, lower right",
            .polygon_list = .{ .start = .{ .x = 20.0, .y = 20.0 }, .end = .{ .x = 30.0, .y = 30.0 } },
            .scale = 1.0,
            .box_height = 10,
            .box_width = 10,
            .expected = false,
        },
        .{
            .name = "scale",
            .polygon_list = .{ .start = .{ .x = 20.0, .y = 20.0 }, .end = .{ .x = 60.0, .y = 60.0 } },
            .scale = 4.0,
            .box_height = 10,
            .box_width = 10,
            .expected = true,
        },
        .{
            .name = "degenerate x axis",
            .polygon_list = .{ .start = .{ .x = 5.0, .y = 2.5 }, .end = .{ .x = 5.0, .y = 7.5 } },
            .scale = 1.0,
            .box_height = 10,
            .box_width = 10,
            .expected = false,
        },
        .{
            .name = "degenerate y axis",
            .polygon_list = .{ .start = .{ .x = 2.5, .y = 5.0 }, .end = .{ .x = 7.5, .y = 5.0 } },
            .scale = 1.0,
            .box_height = 10,
            .box_width = 10,
            .expected = false,
        },
        .{
            .name = "rounding into upper left, x-axis",
            .polygon_list = .{ .start = .{ .x = -2.0, .y = -2.0 }, .end = .{ .x = -0.75, .y = 0.0 } },
            .scale = 1.0,
            .box_height = 10,
            .box_width = 10,
            .expected = true,
        },
        .{
            .name = "rounding into upper left, y-axis",
            .polygon_list = .{ .start = .{ .x = -2.0, .y = -2.0 }, .end = .{ .x = 0.0, .y = -0.75 } },
            .scale = 1.0,
            .box_height = 10,
            .box_width = 10,
            .expected = true,
        },
        .{
            .name = "rounding into lower right, x-axis",
            .polygon_list = .{ .start = .{ .x = 9.5, .y = 9.0 }, .end = .{ .x = 11, .y = 11 } },
            .scale = 1.0,
            .box_height = 10,
            .box_width = 10,
            .expected = true,
        },
        .{
            .name = "rounding into lower right, y-axis",
            .polygon_list = .{ .start = .{ .x = 9.0, .y = 9.5 }, .end = .{ .x = 11, .y = 11 } },
            .scale = 1.0,
            .box_height = 10,
            .box_width = 10,
            .expected = true,
        },
    };
    const TestFn = struct {
        fn f(tc: anytype) TestingError!void {
            try testing.expectEqualDeep(
                tc.expected,
                tc.polygon_list.inBox(tc.scale, tc.box_height, tc.box_width),
            );
        }
    };
    try runCases(name, cases, TestFn.f);
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
