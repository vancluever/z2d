const std = @import("std");
const math = @import("std").math;
const mem = @import("std").mem;
const testing = @import("std").testing;

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
        if (self.nodes.getLast() != .line_to) try self.lineTo(self.last_move_point.?);
        try self.nodes.append(.{ .close_path = .{} });

        // Clear our points. For now, this means consumers will need to be
        // more explicit with path commands (e.g. moving after closing),
        // but it keeps intent clean without overthinking things. We will
        // likely revisit this later.
        self.last_move_point = null;
        self.current_point = null;
    }

    /// Runs a fill operation on this current path and any subpaths. If the
    /// current path is not closed, closes it first.
    ///
    /// This is a no-op if there are no nodes.
    pub fn fill(self: *PathOperation) !void {
        if (self.nodes.items.len == 0) return;
        if (self.nodes.getLast() != .close_path) try self.closePath();

        // Build the polygon and its corners.
        self.polygon.clear();
        try self.polygon.parseNodes(self.nodes.items);

        // Now, for every y in our surface, get our edges and set our fill pixels.
        for (0..self.context.surface.getHeight()) |y| {
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
};

/// Represents a polygon for filling.
pub const Polygon = struct {
    /// The allocator used for allocating the corner list also any returned
    /// edge lists.
    alloc: mem.Allocator,

    /// The corners for the polygon.
    corners: std.ArrayList(Point),

    /// Initializes a polygon with an empty edge list. The caller should run
    /// deinit when done.
    pub fn init(alloc: mem.Allocator) Polygon {
        return .{
            .alloc = alloc,
            .corners = std.ArrayList(Point).init(alloc),
        };
    }

    /// Releases the path node array list. It's invalid to use the
    /// operation after this call.
    pub fn deinit(self: *Polygon) void {
        self.corners.deinit();
    }

    /// Clears all corners in the polygon. Retains capacity. Should be used
    /// before any processing operation.
    pub fn clear(self: *Polygon) void {
        self.corners.clearRetainingCapacity();
    }

    /// Builds corners from a set of PathNode items.
    ///
    /// Does not clear existing polygon corner set. If a clear polygon is
    /// desired, clear should be called.
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
        // TODO: This may not be thread-safe.
        //
        // Scanline and P-I-P algorithms as seen on
        // http://alienryderflex.com/polygon_fill/.
        var edge_list = std.ArrayList(u32).init(self.alloc);
        defer edge_list.deinit();

        // Last index, to compare against current index
        const corners = self.corners.items;
        var last_idx = corners.len - 1;
        for (0..corners.len) |cur_idx| {
            const last_y = corners[last_idx].y;
            const cur_y = corners[cur_idx].y;
            if (cur_y < line_y and last_y >= line_y or cur_y >= line_y and last_y < line_y) {
                const last_x = corners[last_idx].x;
                const cur_x = corners[cur_idx].x;
                try edge_list.append(edge: {
                    const edge_x = cur_x + (line_y - cur_y) / (last_y - cur_y) * (last_x - cur_x);
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

        try polygon.corners.append(self.point);
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
        // least one edge.
        if (current_point == null) return error.PolygonLineToWithoutCurrentPoint;
        if (polygon.corners.items.len == 0) return error.PolygonLineToWithoutCorners;

        try polygon.corners.append(self.point);
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

/// Represents a closepath node. This is a meta-node that indicates a hard
/// close on the current path, and as such has no co-ordinates.
const PathClose = struct {
    /// Plots the node on a polygon.
    fn plotNode(self: PathClose, polygon: *Polygon, current_point: ?Point) !?Point {
        _ = self;
        _ = polygon;
        _ = current_point;

        // Return null for now from closePath. This asserts that all closePaths
        // need to be followed by moveTos, but gives clear behavior; we can
        // alter this in the future.
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
        .{ .close_path = .{} },
    }, path.nodes.items);

    var poly = Polygon.init(testing.allocator);
    defer poly.deinit();
    try poly.parseNodes(path.nodes.items);

    try testing.expectEqualDeep(&[_]Point{
        .{ .x = 0, .y = 0 },
        .{ .x = 199, .y = 0 },
        .{ .x = 100, .y = 199 },
    }, poly.corners.items);

    var edges = try poly.edgesForY(100);
    defer edges.deinit();
    try testing.expectEqualDeep(&[_]u32{ 50, 149 }, edges.items);
}
