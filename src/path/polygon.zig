const std = @import("std");
const math = @import("std").math;
const mem = @import("std").mem;

const units = @import("../units.zig");
const options = @import("../options.zig");

/// Represents an edge on a polygon for a particular y-scanline.
const PolygonEdge = struct {
    x: u32,
    dir: i2,

    fn sort_asc(_: void, a: @This(), b: @This()) bool {
        return a.x < b.x;
    }
};

/// Represents a polygon for filling.
pub const Polygon = struct {
    /// The allocator used for allocating the corner list also any returned
    /// edge lists.
    alloc: mem.Allocator,

    /// The start (upper left) of the polygon rectangle.
    start: units.Point = .{ .x = 0, .y = 0 },

    /// The end (bottom right) of the polygon rectangle.
    end: units.Point = .{ .x = 0, .y = 0 },

    /// The corners for the polygon.
    corners: std.ArrayList(units.Point),

    /// Initializes a polygon with an empty corner list. The caller should run
    /// deinit when done.
    pub fn init(alloc: mem.Allocator) Polygon {
        return .{
            .alloc = alloc,
            .corners = std.ArrayList(units.Point).init(alloc),
        };
    }

    /// Releases this polygon's data. It's invalid to use the operation after
    /// this call.
    pub fn deinit(self: *Polygon) void {
        self.corners.deinit();
    }

    /// Plots a point on the polygon and updates its dimensions.
    pub fn plot(self: *Polygon, p: units.Point) !void {
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

    pub fn edgesForY(self: *Polygon, line_y: f64) !std.ArrayList(PolygonEdge) {
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

        var edge_list = std.ArrayList(PolygonEdge).init(self.alloc);
        defer edge_list.deinit();

        // Get the corners
        const corners = self.corners.items;
        // Last index, to compare against current index
        var last_idx = corners.len - 1;
        for (0..corners.len) |cur_idx| {
            const last_y = corners[last_idx].y;
            const cur_y = corners[cur_idx].y;
            if (cur_y < line_y and last_y >= line_y or cur_y >= line_y and last_y < line_y) {
                const last_x = corners[last_idx].x;
                const cur_x = corners[cur_idx].x;
                try edge_list.append(edge: {
                    // y(x) = (y1 - y0) / (x1 - x0) * (x - x0) + y0
                    //
                    // or:
                    //
                    // x(y) = (y - y0) / (y1 - y0) * (x1 - x0) + x0
                    const edge_x = (line_y - cur_y) / (last_y - cur_y) * (last_x - cur_x) + cur_x;
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
        mem.sort(PolygonEdge, edge_list_sorted, {}, PolygonEdge.sort_asc);
        return std.ArrayList(PolygonEdge).fromOwnedSlice(self.alloc, edge_list_sorted);
    }
};

/// Represents a list of Polygons, intended for multiple subpath operations.
/// Passes most operations down to Polygon.
pub const PolygonList = struct {
    alloc: mem.Allocator,
    items: std.ArrayList(*Polygon),
    start: units.Point = .{ .x = 0, .y = 0 },
    end: units.Point = .{ .x = 0, .y = 0 },

    /// Initializes a new PolygonList. Call deinit to de-initialize the list.
    pub fn init(alloc: mem.Allocator) PolygonList {
        return .{
            .alloc = alloc,
            .items = std.ArrayList(*Polygon).init(alloc),
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

    /// Starts a new Polygon within the list.
    pub fn beginNew(self: *PolygonList) !void {
        const poly = try self.alloc.create(Polygon);
        poly.* = Polygon.init(self.alloc);
        errdefer poly.deinit();
        try self.items.append(poly);
    }

    /// Plots a point on the last Polygon in the list.
    pub fn plot(self: *PolygonList, p: units.Point) !void {
        if (self.items.items.len == 1 and self.items.getLast().corners.items.len == 0) {
            self.start = p;
            self.end = p;
        }

        try self.items.getLast().plot(p);

        if (self.start.x > p.x) self.start.x = p.x;
        if (self.start.y > p.y) self.start.y = p.y;
        if (self.end.x < p.x) self.end.x = p.x;
        if (self.end.y < p.y) self.end.y = p.y;
    }

    /// As an individual edgesForY call, but for all Polygons in the list. This
    /// ensures that corners are checked in the correct order for each Polygon
    /// so that edges are correctly calculated.
    pub fn edgesForY(self: *PolygonList, line_y: f64, fill_rule: options.FillRule) !std.ArrayList(u32) {
        var edge_list = std.ArrayList(PolygonEdge).init(self.alloc);
        defer edge_list.deinit();

        for (self.items.items) |poly| {
            var poly_edge_list = try poly.edgesForY(line_y);
            defer poly_edge_list.deinit();
            try edge_list.appendSlice(poly_edge_list.items);
        }

        const edge_list_sorted = try edge_list.toOwnedSlice();
        mem.sort(PolygonEdge, edge_list_sorted, {}, PolygonEdge.sort_asc);
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
};
