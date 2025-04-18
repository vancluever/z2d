// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024-2025 Chris Marchesi

//! Represents a polygon as a linked list.
const Polygon = @This();

const std = @import("std");
const debug = @import("std").debug;
const heap = @import("std").heap;
const math = @import("std").math;
const mem = @import("std").mem;

pub const CornerList = std.DoublyLinkedList(Point);
const Point = @import("Point.zig");
const PolygonList = @import("PolygonList.zig");
const InternalError = @import("InternalError.zig").InternalError;
const edge_buffer_size = @import("../painter.zig").edge_buffer_size;

corners: CornerList = .{},
start: Point = .{ .x = 0, .y = 0 },
end: Point = .{ .x = 0, .y = 0 },
scale: f64,

pub fn deinit(self: *const Polygon, alloc: mem.Allocator) void {
    var node_ = self.corners.first;
    while (node_) |node| {
        node_ = node.next;
        alloc.destroy(node);
    }
}

/// Plots a point on the polygon. If before is specified, the point is plotted
/// before it.
pub fn plot(
    self: *Polygon,
    alloc: mem.Allocator,
    point: Point,
    before_: ?*CornerList.Node,
) mem.Allocator.Error!void {
    debug.assert(math.isFinite(point.x) and math.isFinite(point.y));
    const n = try alloc.create(CornerList.Node);

    const scaled: Point = .{
        .x = point.x * self.scale,
        .y = point.y * self.scale,
    };

    self.checkUpdateExtents(scaled);

    n.data = scaled;
    if (before_) |before| self.corners.insertBefore(before, n) else self.corners.append(n);
}

/// Like plot, but adds points in the reverse direction (i.e., at the start of
/// the polygon instead of the end.
pub fn plotReverse(self: *Polygon, alloc: mem.Allocator, point: Point) mem.Allocator.Error!void {
    debug.assert(math.isFinite(point.x) and math.isFinite(point.y));
    const n = try alloc.create(CornerList.Node);

    const scaled: Point = .{
        .x = point.x * self.scale,
        .y = point.y * self.scale,
    };

    self.checkUpdateExtents(scaled);

    n.data = scaled;
    self.corners.prepend(n);
}

fn checkUpdateExtents(self: *Polygon, point: Point) void {
    if (self.corners.len == 0) {
        self.start = point;
        self.end = point;
    } else {
        if (self.start.x > point.x) self.start.x = point.x;
        if (self.start.y > point.y) self.start.y = point.y;
        if (self.end.x < point.x) self.end.x = point.x;
        if (self.end.y < point.y) self.end.y = point.y;
    }
}

/// Concatenates a polygon into this one. It's invalid to use the other polygon
/// after this operation is done.
pub fn concat(self: *Polygon, other: Polygon) mem.Allocator.Error!void {
    concatByCopying(&self.corners, &other.corners);

    self.checkUpdateExtents(other.start);
    self.checkUpdateExtents(other.end);
}

/// Re-implemented from stdlib to just strip the invalidation of the second
/// list, to allow for const-ness.
fn concatByCopying(list1: *CornerList, list2: *const CornerList) void {
    const l2_first = list2.first orelse return;
    if (list1.last) |l1_last| {
        l1_last.next = list2.first;
        l2_first.prev = list1.last;
        list1.len += list2.len;
    } else {
        // list1 was empty
        list1.first = list2.first;
        list1.len = list2.len;
    }
    list1.last = list2.last;
}

/// Represents an edge on a polygon for a particular y-scanline.
pub const Edge = packed struct {
    // The size of our x-edge.
    //
    // TODO: This ultimately places a limit on our edge size to i30 currently
    // (approx. +/- 536870912). This is set up to ensure this struct fits in a
    // u32 as this our edges are stored in a very small buffer.
    //
    // Note that our internal numerics are not 100% yet decided on, so this
    // limit may change (and will likely decrease versus increase).
    pub const X = i30;

    x: X,
    dir: i2,

    pub fn sort_asc(_: void, a: Edge, b: Edge) bool {
        return a.x < b.x;
    }
};

pub const EdgesForYError = InternalError || mem.Allocator.Error;

pub fn edgesForY(
    self: *const Polygon,
    alloc: mem.Allocator,
    line_y: f64,
) EdgesForYError!std.ArrayListUnmanaged(Edge) {
    // Get a sorted list of X-edges suitable for traversal in a scanline
    // fill. For an in-depth explanation on how this works, see "Efficient
    // Polygon Fill Algorithm With C Code Sample" by Darel Rex Finley
    // (http://alienryderflex.com/polygon_fill/, archive link:
    // http://web.archive.org/web/20240102043551/http://alienryderflex.com/polygon_fill/).
    // Parts of this section follows the public-domain code listed in the
    // sample.

    // See PolygonList.edgesForY for more details on FBA organization and
    // initial capacity.
    const edge_buffer_item_size = edge_buffer_size / @sizeOf(Edge);
    const edge_list_capacity = edge_buffer_item_size - (edge_buffer_item_size / 3 * 2);
    var edge_list = try std.ArrayListUnmanaged(Edge).initCapacity(alloc, edge_list_capacity);
    if (self.corners.len == 0) return edge_list;
    defer edge_list.deinit(alloc);

    // We take our line measurements at the middle of the line; this helps
    // "break the tie" with lines that fall exactly on point boundaries.
    debug.assert(@floor(line_y) == line_y);
    const line_y_middle = line_y + 0.5;

    var current_ = self.corners.first;
    if (self.corners.last == null) return InternalError.InvalidState;
    var last = self.corners.last.?;
    while (current_) |current| : (current_ = current.next) {
        const last_y = last.data.y;
        const cur_y = current.data.y;
        if (cur_y < line_y_middle and last_y >= line_y_middle or
            cur_y >= line_y_middle and last_y < line_y_middle)
        {
            const last_x = last.data.x;
            const cur_x = current.data.x;
            try edge_list.append(alloc, edge: {
                // y(x) = (y1 - y0) / (x1 - x0) * (x - x0) + y0
                //
                // or:
                //
                // x(y) = (y - y0) / (y1 - y0) * (x1 - x0) + x0
                const edge_x = @round(
                    (line_y_middle - cur_y) / (last_y - cur_y) * (last_x - cur_x) + cur_x,
                );
                break :edge .{
                    .x = math.clamp(@as(Edge.X, @intFromFloat(edge_x)), 0, math.maxInt(Edge.X)),
                    // Apply the edge direction to the winding number.
                    // Down-up is +1, up-down is -1.
                    .dir = if (cur_y > last_y)
                        -1
                    else if (cur_y < last_y)
                        1
                    else
                        return InternalError.InvalidState, // We have already filtered out horizontal edges
                };
            });
        }

        last = current;
    }

    // Sort our edges
    const edge_list_sorted = try edge_list.toOwnedSlice(alloc);
    mem.sort(Edge, edge_list_sorted, {}, Edge.sort_asc);
    return std.ArrayListUnmanaged(Edge).fromOwnedSlice(edge_list_sorted);
}
