//! Represents a polygon as a linked list.
const Polygon = @This();

const std = @import("std");
const debug = @import("std").debug;
const heap = @import("std").heap;
const math = @import("std").math;
const mem = @import("std").mem;

pub const CornerList = std.DoublyLinkedList(Point);
const Point = @import("Point.zig");

arena_alloc: heap.ArenaAllocator,
concatenated_polygons: std.ArrayList(Polygon),
corners: CornerList = .{},
start: Point = .{ .x = 0, .y = 0 },
end: Point = .{ .x = 0, .y = 0 },
scale: f64,

pub fn init(alloc: mem.Allocator, scale: f64) Polygon {
    return .{
        .arena_alloc = heap.ArenaAllocator.init(alloc),
        .concatenated_polygons = std.ArrayList(Polygon).init(alloc),
        .scale = scale,
    };
}

pub fn deinit(self: *const Polygon) void {
    for (self.concatenated_polygons.items) |poly| poly.deinit();
    self.concatenated_polygons.deinit();
    self.arena_alloc.deinit();
}

/// Plots a point on the polygon. If before is specified, the point is plotted
/// before it.
pub fn plot(self: *Polygon, point: Point, before_: ?*CornerList.Node) !void {
    const n = try self.arena_alloc.allocator().create(CornerList.Node);

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
pub fn plotReverse(self: *Polygon, point: Point) !void {
    const n = try self.arena_alloc.allocator().create(CornerList.Node);

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
pub fn concat(self: *Polygon, other: Polygon) !void {
    try self.concatenated_polygons.append(other);
    concatByCopying(&self.corners, &other.corners);
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
pub const Edge = struct {
    x: u32,
    dir: i2,

    pub fn sort_asc(_: void, a: Edge, b: Edge) bool {
        return a.x < b.x;
    }
};

pub fn edgesForY(self: *const Polygon, alloc: mem.Allocator, line_y: f64) !std.ArrayList(Edge) {
    // Get a sorted list of X-edges suitable for traversal in a scanline
    // fill. For an in-depth explanation on how this works, see "Efficient
    // Polygon Fill Algorithm With C Code Sample" by Darel Rex Finley
    // (http://alienryderflex.com/polygon_fill/, archive link:
    // http://web.archive.org/web/20240102043551/http://alienryderflex.com/polygon_fill/).
    // Parts of this section follows the public-domain code listed in the
    // sample.

    var edge_list = std.ArrayList(Edge).init(alloc);
    if (self.corners.len == 0) return edge_list;
    defer edge_list.deinit();

    // We take our line measurements at the middle of the line; this helps
    // "break the tie" with lines that fall exactly on point boundaries.
    debug.assert(@floor(line_y) == line_y);
    const line_y_middle = line_y + 0.5;

    var current_ = self.corners.first;
    debug.assert(self.corners.last != null);
    var last = self.corners.last.?;
    while (current_) |current| : (current_ = current.next) {
        const last_y = last.data.y;
        const cur_y = current.data.y;
        if (cur_y < line_y_middle and last_y >= line_y_middle or
            cur_y >= line_y_middle and last_y < line_y_middle)
        {
            const last_x = last.data.x;
            const cur_x = current.data.x;
            try edge_list.append(edge: {
                // y(x) = (y1 - y0) / (x1 - x0) * (x - x0) + y0
                //
                // or:
                //
                // x(y) = (y - y0) / (y1 - y0) * (x1 - x0) + x0
                const edge_x = @round(
                    (line_y_middle - cur_y) / (last_y - cur_y) * (last_x - cur_x) + cur_x,
                );
                break :edge .{
                    .x = @max(0, @min(math.maxInt(u32), @as(u32, @intFromFloat(edge_x)))),
                    // Apply the edge direction to the winding number.
                    // Down-up is +1, up-down is -1.
                    .dir = if (cur_y > last_y)
                        -1
                    else if (cur_y < last_y)
                        1
                    else
                        unreachable, // We have already filtered out horizontal edges
                };
            });
        }

        last = current;
    }

    // Sort our edges
    const edge_list_sorted = try edge_list.toOwnedSlice();
    mem.sort(Edge, edge_list_sorted, {}, Edge.sort_asc);
    return std.ArrayList(Edge).fromOwnedSlice(alloc, edge_list_sorted);
}
