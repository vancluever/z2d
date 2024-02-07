const std = @import("std");
const math = @import("std").math;
const mem = @import("std").mem;

const units = @import("../units.zig");

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

    /// For a given y-coordinate, return a sorted slice of edge x-coordinates,
    /// defining the boundaries for the polygon at that line. This slice is
    /// appropriate for filling using an even-odd rule.
    ///
    /// The caller owns the returned ArrayList and should use deinit to release
    /// it.
    pub fn edgesForY(self: *Polygon, line_y: f64) !std.ArrayList(u32) {
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

        var edge_list = std.ArrayList(u32).init(self.alloc);
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
                    break :edge @max(0, @min(math.maxInt(u32), @as(u32, @intFromFloat(edge_x))));
                });
            }

            last_idx = cur_idx;
        }

        // Sort and return.
        const edge_list_sorted = try edge_list.toOwnedSlice();
        mem.sort(u32, edge_list_sorted, {}, comptime (std.sort.asc(u32)));
        return std.ArrayList(u32).fromOwnedSlice(self.alloc, edge_list_sorted);
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
        if (self.items.items.len == 0) {
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
    pub fn edgesForY(self: *PolygonList, line_y: f64) !std.ArrayList(u32) {
        var edge_list = std.ArrayList(u32).init(self.alloc);
        defer edge_list.deinit();

        for (self.items.items) |poly| {
            var poly_edge_list = try poly.edgesForY(line_y);
            defer poly_edge_list.deinit();
            try edge_list.appendSlice(poly_edge_list.items);
        }

        const edge_list_sorted = try edge_list.toOwnedSlice();
        mem.sort(u32, edge_list_sorted, {}, comptime (std.sort.asc(u32)));
        return std.ArrayList(u32).fromOwnedSlice(self.alloc, edge_list_sorted);
    }
};
