const std = @import("std");
const math = @import("std").math;
const mem = @import("std").mem;
const testing = @import("std").testing;

const bresenham = @import("bresenham.zig");
const spline = @import("spline.zig");
const contextpkg = @import("context.zig");

/// Represents a point in 2D space.
pub const Point = struct {
    x: f64,
    y: f64,

    /// Checks to see if a point is equal to another point.
    pub fn equal(self: Point, other: Point) bool {
        return self.x == other.x and self.y == other.y;
    }
};

/// A path drawing operation, resulting in a rendered complex set of one or
/// more polygons.
pub const PathOperation = struct {
    /// A reference back to the draw context.
    ///
    /// private: should not be edited directly.
    context: *contextpkg.DrawContext,

    /// The set of path nodes.
    ///
    /// private: should not be edited directly.
    nodes: std.ArrayList(PathNode),

    /// The polygon for drawing.
    ///
    /// NOTE: This is embedded in the path operation only so that the
    /// allocation path for path operations is clean (e.g. allocator is
    /// supplied to init and only init; otherwise this would also need to be
    /// supplied for fill operations as well).
    ///
    /// private: should not be edited directly.
    polygon: Polygon,

    /// The start of the current subpath when working with drawing
    /// operations.
    ///
    /// private: should not be edited directly.
    last_move_point: ?Point = null,

    /// The current point when working with drawing operations.
    ///
    /// private: should not be edited directly.
    current_point: ?Point = null,

    /// Initializes the path operation. Call deinit to release the node
    /// list when complete.
    pub fn init(alloc: mem.Allocator, context: *contextpkg.DrawContext) PathOperation {
        return .{
            .context = context,
            .nodes = std.ArrayList(PathNode).init(alloc),
            .polygon = Polygon.init(alloc),
        };
    }

    /// Releases the path node array list. It's invalid to use the
    /// operation after this call.
    pub fn deinit(self: *PathOperation) void {
        self.polygon.deinit();
        self.nodes.deinit();
    }

    /// Starts a new path, and moves the current point to it.
    pub fn moveTo(self: *PathOperation, point: Point) !void {
        try self.nodes.append(.{ .move_to = .{ .point = point } });
        self.last_move_point = point;
        self.current_point = point;
    }

    /// Draws a line from the current point to the specified point and sets
    /// it as the current point.
    ///
    /// Acts as a moveTo instead if there is no current point.
    pub fn lineTo(self: *PathOperation, point: Point) !void {
        if (self.current_point == null) return self.moveTo(point);
        try self.nodes.append(.{ .line_to = .{ .point = point } });
        self.current_point = point;
    }

    /// Draws a cubic bezier with the three supplied control points from
    /// the current point. The new current point is set to p3.
    ///
    /// It is an error to call this without a current point.
    pub fn curveTo(self: *PathOperation, p1: Point, p2: Point, p3: Point) !void {
        if (self.current_point == null) return error.PathOperationCurveToNoCurrentPoint;
        try self.nodes.append(.{ .curve_to = .{ .p1 = p1, .p2 = p2, .p3 = p3 } });
        self.current_point = p3;
    }

    /// Closes the path by drawing a line from the current point by the
    /// starting point. No effect if there is no current point.
    pub fn closePath(self: *PathOperation) !void {
        if (self.current_point == null) return;
        if (self.last_move_point == null) return error.PathOperationClosePathNoLastMovePoint;
        try self.nodes.append(.{ .close_path = .{ .point = self.last_move_point.? } });

        // Clear our points. For now, this means consumers will need to be
        // more explicit with path commands (e.g. moving after closing),
        // but it keeps intent clean without overthinking things. We will
        // likely revisit this later.
        self.last_move_point = null;
        self.current_point = null;
    }

    /// Runs a fill operation (even-odd) on this current path and any subpaths.
    /// If the current path is not closed, closes it first.
    ///
    /// This is a no-op if there are no nodes.
    pub fn fill(self: *PathOperation) !void {
        if (self.nodes.items.len == 0) return;
        if (self.nodes.getLast() != .close_path) try self.closePath();

        // Build the polygon
        self.polygon.clear();
        try self.polygon.parseNodes(self.nodes.items);

        // Now, for every y in our surface, get our edges and set our fill pixels.
        const poly_start_y: usize = @intFromFloat(self.polygon.start.y);
        const poly_end_y: usize = @intFromFloat(self.polygon.end.y);
        for (poly_start_y..poly_end_y + 1) |y| {
            // Get our edges for this y
            var edge_list = try self.polygon.edgesForY(@floatFromInt(y));
            defer edge_list.deinit();

            // Currently even-odd fill only. TODO: add non-zero.
            var start_idx: usize = 0;
            while (start_idx + 1 < edge_list.items.len) {
                const start_x = @min(
                    self.context.surface.getWidth(),
                    edge_list.items[start_idx],
                );
                const end_x = @min(
                    self.context.surface.getWidth(),
                    edge_list.items[start_idx + 1],
                );

                for (start_x..end_x + 1) |x| {
                    const pixel = try self.context.pattern.getPixel(@intCast(x), @intCast(y));
                    try self.context.surface.putPixel(@intCast(x), @intCast(y), pixel);
                }

                start_idx += 2;
            }
        }
    }

    /// Draws a line along the current path.
    ///
    /// This is a no-op if there are no nodes.
    pub fn stroke(self: *PathOperation) !void {
        if (self.nodes.items.len == 0) return;

        // Build the polygon
        self.polygon.clear();
        try self.polygon.parseNodes(self.nodes.items);

        // Start drawing our edges.
        for (self.polygon.edges.items) |edge| {
            if (edge.isHorizontal()) {
                // Horizontal line
                const y = u32Clamped(edge.start.y);
                const start_x = if (edge.start.x > edge.end.x)
                    u32Clamped(edge.end.x)
                else
                    u32Clamped(edge.start.x);
                const end_x = if (edge.start.x > edge.end.x)
                    u32Clamped(edge.start.x)
                else
                    u32Clamped(edge.end.x);
                for (start_x..end_x + 1) |x| {
                    const pixel = try self.context.pattern.getPixel(@intCast(x), y);
                    try self.context.surface.putPixel(@intCast(x), y, pixel);
                }
            } else if (edge.isVertical()) {
                // Vertical line
                const x = u32Clamped(edge.start.x);
                const start_y = if (edge.start.y > edge.end.y)
                    u32Clamped(edge.end.y)
                else
                    u32Clamped(edge.start.y);
                const end_y = if (edge.start.y > edge.end.y)
                    u32Clamped(edge.start.y)
                else
                    u32Clamped(edge.end.y);
                for (start_y..end_y + 1) |y| {
                    const pixel = try self.context.pattern.getPixel(x, @intCast(y));
                    try self.context.surface.putPixel(x, @intCast(y), pixel);
                }
            } else {
                if (edge.isSteep()) {
                    // Steep slope, we need to iterate on the y
                    if (edge.start.y > edge.end.y) {
                        try bresenham.drawIterY(self.context, edge.end, edge.start);
                    } else {
                        try bresenham.drawIterY(self.context, edge.start, edge.end);
                    }
                } else {
                    // Normal slope, iterate on the x
                    if (edge.start.x > edge.end.x) {
                        try bresenham.drawIterX(self.context, edge.end, edge.start);
                    } else {
                        try bresenham.drawIterX(self.context, edge.start, edge.end);
                    }
                }
            }
        }
    }
};

/// Represents a polygon for filling.
pub const Polygon = struct {
    /// The allocator used for allocating the corner list also any returned
    /// edge lists.
    alloc: mem.Allocator,

    /// The start (upper left) of the polygon rectangle.
    start: Point = .{ .x = 0, .y = 0 },

    /// The end (bottom right) of the polygon rectangle.
    end: Point = .{ .x = 0, .y = 0 },

    /// The corners for the polygon.
    corners: std.ArrayList(Point),

    /// The edges for the polygon. These are essentially lines with metadata.
    edges: std.ArrayList(PolygonEdge),

    /// Initializes a polygon with an empty edge list. The caller should run
    /// deinit when done.
    pub fn init(alloc: mem.Allocator) Polygon {
        return .{
            .alloc = alloc,
            .corners = std.ArrayList(Point).init(alloc),
            .edges = std.ArrayList(PolygonEdge).init(alloc),
        };
    }

    /// Releases this polygon's corners and edges. It's invalid to use the
    /// operation after this call.
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
    pub fn plot(self: *Polygon, p: Point) !void {
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

    /// Builds corners and edges from a set of PathNode items.
    ///
    /// Does not clear existing items. If a clean polygon is desired, clear
    /// should be called.
    pub fn parseNodes(self: *Polygon, nodes: []PathNode) !void {
        var lastPoint: ?Point = null;
        for (nodes) |node| {
            lastPoint = switch (node) {
                .move_to => |n| try n.plotNode(self, lastPoint),
                .line_to => |n| try n.plotNode(self, lastPoint),
                .curve_to => |n| try n.plotNode(self, lastPoint),
                .close_path => |n| try n.plotNode(self, lastPoint),
            };
        }
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
                    break :edge u32Clamped(edge_x);
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

const PolygonEdge = struct {
    start: Point,
    end: Point,

    pub fn fromPoints(start: Point, end: Point) PolygonEdge {
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

/// Represents a moveto path node. This starts a new subpath and moves the
/// current point to (x, y).
const PathMoveTo = struct {
    point: Point,

    /// Plots the node on a polygon.
    fn plotNode(self: PathMoveTo, polygon: *Polygon, current_point: ?Point) !?Point {
        // current_point should be null here, and there should be no edges. We
        // might change this in the future, but as we are being explicit
        // currently, we want to make sure that this is the start of the
        // polygon.
        if (current_point != null) return error.PolygonMoveToWithCurrentPoint;
        if (polygon.corners.items.len != 0) return error.PolygonMoveToOnNonZeroCorners;

        try polygon.plot(self.point);
        return self.point;
    }
};

/// Represents a lineto path node. This draws a line to (x, y) and sets it as
/// its current point.
const PathLineTo = struct {
    point: Point,

    /// Plots the node on a polygon.
    fn plotNode(self: PathLineTo, polygon: *Polygon, current_point: ?Point) !?Point {
        // We've already reduced our node list by this point in time, so we
        // should always have a current point (e.g. at least moveto), and at
        // least one corner.
        if (current_point == null) return error.PolygonLineToWithoutCurrentPoint;
        if (polygon.corners.items.len == 0) return error.PolygonLineToWithoutCorners;

        try polygon.plot(self.point);
        return self.point;
    }
};

/// Represents a curveto path node. This draws a cubic bezier with the three
/// supplied control points from the current point. The new current point is
/// set to p3.
const PathCurveTo = struct {
    p1: Point,
    p2: Point,
    p3: Point,

    /// Plots the node on a polygon.
    fn plotNode(self: PathCurveTo, polygon: *Polygon, current_point: ?Point) !?Point {
        // Assert that we have a current point and at least one edge. These are
        // the same assertions that we make on the higher-level curveTo
        // function as well.
        if (current_point == null) return error.PolygonCurveToWithoutCurrentPoint;
        if (polygon.corners.items.len == 0) return error.PolygonCurveToWithoutCorners;

        var sp = spline.Spline.init(polygon, current_point.?, self.p1, self.p2, self.p3) catch |err| {
            if (err == error.SplineIsALine) {
                // Degenerate curve - just a line to p3
                return (PathLineTo{ .point = self.p3 }).plotNode(polygon, current_point);
            } else {
                return err;
            }
        };

        // TODO: Make the error tolerance configurable.
        try sp.decompose(0.1);
        return self.p3;
    }
};

/// Represents a closepath node. The close is done by connecting the last point
/// to the first moveTo point, which is stored in this node (under "point").
const PathClose = struct {
    point: Point,

    /// Plots the node on a polygon.
    fn plotNode(self: PathClose, polygon: *Polygon, current_point: ?Point) !?Point {
        // Assert that we have a current point. Our higher-level closePath
        // method no-ops when it's called without one, so this will never be
        // null.
        if (current_point == null) return error.PolygonClosePathToWithoutCurrentPoint;

        // Do an append on the edges only for now (not corners). We will
        // simplify this when we remove corners, for now this keeps the
        // starting corner from being duplicated.
        try polygon.edges.append(PolygonEdge.fromPoints(current_point.?, self.point));
        return null;
    }
};

/// A tagged union of all path node types.
const PathNodeTag = enum {
    move_to,
    line_to,
    curve_to,
    close_path,
};

const PathNode = union(PathNodeTag) {
    move_to: PathMoveTo,
    line_to: PathLineTo,
    curve_to: PathCurveTo,
    close_path: PathClose,
};

fn u32Clamped(x: f64) u32 {
    return @max(0, @min(math.maxInt(u32), @as(u32, @intFromFloat(x))));
}

test "PathOperation, triangle" {
    var path = PathOperation.init(testing.allocator, undefined);
    defer path.deinit();
    try path.moveTo(.{ .x = 0, .y = 0 });
    try path.lineTo(.{ .x = 199, .y = 0 });
    try path.lineTo(.{ .x = 100, .y = 199 });
    try path.closePath();

    try testing.expectEqualDeep(&[_]PathNode{
        .{ .move_to = .{ .point = .{ .x = 0, .y = 0 } } },
        .{ .line_to = .{ .point = .{ .x = 199, .y = 0 } } },
        .{ .line_to = .{ .point = .{ .x = 100, .y = 199 } } },
        .{ .close_path = .{ .point = .{ .x = 0, .y = 0 } } },
    }, path.nodes.items);

    var poly = Polygon.init(testing.allocator);
    defer poly.deinit();
    try poly.parseNodes(path.nodes.items);

    try testing.expectEqual(Point{ .x = 0, .y = 0 }, poly.start);
    try testing.expectEqual(Point{ .x = 199, .y = 199 }, poly.end);

    try testing.expectEqualDeep(&[_]Point{
        .{ .x = 0, .y = 0 },
        .{ .x = 199, .y = 0 },
        .{ .x = 100, .y = 199 },
    }, poly.corners.items);

    try testing.expectEqualDeep(&[_]PolygonEdge{
        .{ .start = .{ .x = 0, .y = 0 }, .end = .{ .x = 199, .y = 0 } },
        .{ .start = .{ .x = 199, .y = 0 }, .end = .{ .x = 100, .y = 199 } },
        .{ .start = .{ .x = 100, .y = 199 }, .end = .{ .x = 0, .y = 0 } },
    }, poly.edges.items);

    var edges = try poly.edgesForY(100);
    defer edges.deinit();
    try testing.expectEqualDeep(&[_]u32{ 50, 149 }, edges.items);
}
