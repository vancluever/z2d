//! Represents a list of Polygons, intended for multiple subpath operations.
//! Passes most operations down to Polygon.
const PolygonList = @This();

const std = @import("std");
const debug = @import("std").debug;
const math = @import("std").math;
const mem = @import("std").mem;

const FillRule = @import("../options.zig").FillRule;
const PathNode = @import("nodes.zig").PathNode;
const Point = @import("../units.zig").Point;
const spline = @import("spline_transformer.zig");

alloc: mem.Allocator,
items: std.ArrayList(*Polygon),
scale: f64,
start: Point = .{ .x = 0, .y = 0 },
end: Point = .{ .x = 0, .y = 0 },

/// Parses the node list and plots the points therein, and returns a polygon
/// list suitable for filling.
///
/// The caller owns the polygon list and needs to call deinit on it.
pub fn initNodes(
    alloc: mem.Allocator,
    nodes: std.ArrayList(PathNode),
    scale: f64,
) !PolygonList {
    var polygon_list = PolygonList.init(alloc, scale);
    errdefer polygon_list.deinit();

    var initial_point: ?Point = null;
    var current_point: ?Point = null;

    for (nodes.items, 0..) |node, i| {
        switch (node) {
            .move_to => |n| {
                // Check if this is the last node, and no-op if it is, as this
                // is the auto-added move_to node that is given after
                // close_path.
                if (i == nodes.items.len - 1) {
                    break;
                }

                try polygon_list.beginNew();
                try polygon_list.plot(n.point);
                initial_point = n.point;
                current_point = n.point;
            },
            .line_to => |n| {
                debug.assert(initial_point != null);
                debug.assert(current_point != null);

                try polygon_list.plot(n.point);
                current_point = n.point;
            },
            .curve_to => |n| {
                debug.assert(initial_point != null);
                debug.assert(current_point != null);

                var transformed_nodes = try spline.transform(
                    alloc,
                    current_point.?,
                    n.p1,
                    n.p2,
                    n.p3,
                    0.1, // TODO: make tolerance configurable
                );
                defer transformed_nodes.deinit();

                // We just iterate through the node list here and plot directly.
                for (transformed_nodes.items) |tn| {
                    switch (tn) {
                        .line_to => |tnn| try polygon_list.plot(tnn.point),
                        else => unreachable, // spline transformer does not return anything else
                    }
                }
            },
            .close_path => {
                debug.assert(initial_point != null);
                debug.assert(current_point != null);

                // No-op if our initial and current points are equal
                if (current_point.?.equal(initial_point.?)) break;

                // Set the current point to the initial point.
                current_point = initial_point;
            },
        }
    }

    return polygon_list;
}

/// Initializes a new PolygonList. Call deinit to de-initialize the list.
fn init(alloc: mem.Allocator, scale: f64) PolygonList {
    return .{
        .alloc = alloc,
        .items = std.ArrayList(*Polygon).init(alloc),
        .scale = scale,
    };
}

/// Frees the entire list and its underlying memory.
pub fn deinit(self: *PolygonList) void {
    for (self.items.items) |poly| {
        poly.deinit();
        self.alloc.destroy(poly);
    }
    self.items.deinit();
}

/// As an individual edgesForY call, but for all Polygons in the list. This
/// ensures that corners are checked in the correct order for each Polygon
/// so that edges are correctly calculated.
pub fn edgesForY(self: *PolygonList, line_y: f64, fill_rule: FillRule) !std.ArrayList(u32) {
    var edge_list = std.ArrayList(Edge).init(self.alloc);
    defer edge_list.deinit();

    for (self.items.items) |poly| {
        var poly_edge_list = try poly.edgesForY(line_y);
        defer poly_edge_list.deinit();
        try edge_list.appendSlice(poly_edge_list.items);
    }

    const edge_list_sorted = try edge_list.toOwnedSlice();
    mem.sort(Edge, edge_list_sorted, {}, Edge.sort_asc);
    defer self.alloc.free(edge_list_sorted);

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
    var final_edge_list = try std.ArrayList(u32).initCapacity(self.alloc, edge_list_sorted.len);
    errdefer final_edge_list.deinit();
    var winding_number: i32 = 0;
    var start: u32 = undefined;
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

/// Starts a new Polygon within the list.
fn beginNew(self: *PolygonList) !void {
    const poly = try self.alloc.create(Polygon);
    poly.* = Polygon.init(self.alloc);
    errdefer poly.deinit();
    try self.items.append(poly);
}

/// Plots a point on the last Polygon in the list.
fn plot(self: *PolygonList, p: Point) !void {
    const scaled: Point = .{
        .x = p.x * self.scale,
        .y = p.y * self.scale,
    };

    if (self.items.items.len == 1 and self.items.getLast().corners.items.len == 0) {
        self.start = scaled;
        self.end = scaled;
    }

    try self.items.getLast().plot(scaled);

    if (self.start.x > scaled.x) self.start.x = scaled.x;
    if (self.start.y > scaled.y) self.start.y = scaled.y;
    if (self.end.x < scaled.x) self.end.x = scaled.x;
    if (self.end.y < scaled.y) self.end.y = scaled.y;
}

/// Represents an edge on a polygon for a particular y-scanline.
const Edge = struct {
    x: u32,
    dir: i2,

    fn sort_asc(_: void, a: Edge, b: Edge) bool {
        return a.x < b.x;
    }
};

/// Represents a polygon for filling.
const Polygon = struct {
    /// The allocator used for allocating the corner list also any returned
    /// edge lists.
    alloc: mem.Allocator,

    /// The start (upper left) of the polygon rectangle.
    start: Point = .{ .x = 0, .y = 0 },

    /// The end (bottom right) of the polygon rectangle.
    end: Point = .{ .x = 0, .y = 0 },

    /// The corners for the polygon.
    corners: std.ArrayList(Point),

    /// Initializes a polygon with an empty corner list. The caller should run
    /// deinit when done.
    fn init(alloc: mem.Allocator) Polygon {
        return .{
            .alloc = alloc,
            .corners = std.ArrayList(Point).init(alloc),
        };
    }

    /// Releases this polygon's data. It's invalid to use the operation after
    /// this call.
    fn deinit(self: *Polygon) void {
        self.corners.deinit();
    }

    /// Plots a point on the polygon and updates its dimensions.
    fn plot(self: *Polygon, p: Point) !void {
        if (self.corners.items.len == 0) {
            self.start = p;
            self.end = p;
        }
        try self.corners.append(p);

        if (self.start.x > p.x) self.start.x = p.x;
        if (self.start.y > p.y) self.start.y = p.y;
        if (self.end.x < p.x) self.end.x = p.x;
        if (self.end.y < p.y) self.end.y = p.y;
    }

    fn edgesForY(self: *Polygon, line_y: f64) !std.ArrayList(Edge) {
        // As mentioned in the method description, the point of this function
        // is to get a (sorted) list of X-edges so that we can do a scanline
        // fill on a polygon. The function does this by calculating edges based
        // on a last -> current vertex (corner) basis.
        //
        // For an in-depth explanation on how this works, see "Efficient
        // Polygon Fill Algorithm With C Code Sample" by Darel Rex Finley
        // (http://alienryderflex.com/polygon_fill/, archive link:
        // http://web.archive.org/web/20240102043551/http://alienryderflex.com/polygon_fill/).
        // Parts of this section follows the public-domain code listed in the
        // sample.

        var edge_list = std.ArrayList(Edge).init(self.alloc);
        defer edge_list.deinit();

        // We take our line measurements at the middle of the line; this helps
        // "break the tie" with lines that fall exactly on point boundaries.
        debug.assert(@floor(line_y) == line_y);
        const line_y_middle = line_y + 0.5;

        // Get the corners
        const corners = self.corners.items;
        // Last index, to compare against current index
        var last_idx = corners.len - 1;
        for (0..corners.len) |cur_idx| {
            const last_y = corners[last_idx].y;
            const cur_y = corners[cur_idx].y;
            if (cur_y < line_y_middle and last_y >= line_y_middle or
                cur_y >= line_y_middle and last_y < line_y_middle)
            {
                const last_x = corners[last_idx].x;
                const cur_x = corners[cur_idx].x;
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

            last_idx = cur_idx;
        }

        // Sort our edges
        const edge_list_sorted = try edge_list.toOwnedSlice();
        mem.sort(Edge, edge_list_sorted, {}, Edge.sort_asc);
        return std.ArrayList(Edge).fromOwnedSlice(self.alloc, edge_list_sorted);
    }
};
