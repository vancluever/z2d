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

    /// The edges for the polygon. These are essentially lines with metadata.
    edges: std.ArrayList(PolygonEdge),

    /// Initializes a polygon with an empty edge list. The caller should run
    /// deinit when done.
    pub fn init(alloc: mem.Allocator) Polygon {
        return .{
            .alloc = alloc,
            .corners = std.ArrayList(units.Point).init(alloc),
            .edges = std.ArrayList(PolygonEdge).init(alloc),
        };
    }

    /// Releases this polygon's data. It's invalid to use the operation after
    /// this call.
    pub fn deinit(self: *Polygon) void {
        self.corners.deinit();
        self.edges.deinit();
    }

    /// Releases this polygon's corners and edges. Retains capacity. Should be
    /// used before any processing operation.
    pub fn clear(self: *Polygon) void {
        self.corners.clearRetainingCapacity();
        self.edges.clearRetainingCapacity();
    }

    /// Plots a point on the polygon. Adds to the current corner list, and if
    /// this is non-zero, computes an edge as well.
    pub fn plot(self: *Polygon, p: units.Point) !void {
        if (self.corners.items.len > 0) {
            try self.edges.append(PolygonEdge.fromPoints(self.corners.getLast(), p));
        } else {
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

pub const PolygonEdge = struct {
    start: units.Point,
    end: units.Point,

    pub fn fromPoints(start: units.Point, end: units.Point) PolygonEdge {
        return .{
            .start = start,
            .end = end,
        };
    }

    pub fn isHorizontal(self: PolygonEdge) bool {
        return self.start.y == self.end.y;
    }

    pub fn isVertical(self: PolygonEdge) bool {
        return self.start.x == self.end.x;
    }

    pub fn isSteep(self: PolygonEdge) bool {
        return @abs(self.end.y - self.start.y) >= @abs(self.end.x - self.start.x);
    }
};
