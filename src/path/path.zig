const std = @import("std");
const mem = @import("std").mem;

const nodepkg = @import("nodes.zig");
const units = @import("../units.zig");

/// A path drawing operation, resulting in a rendered complex set of one or
/// more polygons.
pub const PathOperation = struct {
    /// The set of path nodes.
    nodes: std.ArrayList(nodepkg.PathNode),

    /// The start of the current subpath when working with drawing
    /// operations.
    last_move_point: ?units.Point = null,

    /// The current point when working with drawing operations.
    current_point: ?units.Point = null,

    /// Initializes the path operation. Call deinit to release the node
    /// list when complete.
    pub fn init(alloc: mem.Allocator) PathOperation {
        return .{
            .nodes = std.ArrayList(nodepkg.PathNode).init(alloc),
        };
    }

    /// Releases the path node array list. It's invalid to use the
    /// operation after this call.
    pub fn deinit(self: *PathOperation) void {
        self.nodes.deinit();
    }

    /// Rests the path operation, clearing all nodes and state.
    pub fn reset(self: *PathOperation) void {
        self.nodes.clearRetainingCapacity();
        self.last_move_point = null;
        self.current_point = null;
    }

    /// Starts a new path, and moves the current point to it.
    pub fn moveTo(self: *PathOperation, point: units.Point) !void {
        // If our last operation is a move_to to this point, this is a no-op.
        // This ensures that there's no duplicates on things like explicit
        // definitions on close_path -> move_to (versus the implicit add in the
        // closePath operation).
        if (self.nodes.getLastOrNull()) |node| {
            switch (node) {
                .move_to => |move_to| {
                    if (move_to.point.equal(point)) return;
                },
                else => {},
            }
        }

        try self.nodes.append(.{ .move_to = .{ .point = point } });
        self.last_move_point = point;
        self.current_point = point;
    }

    /// Draws a line from the current point to the specified point and sets
    /// it as the current point.
    ///
    /// Acts as a moveTo instead if there is no current point.
    pub fn lineTo(self: *PathOperation, point: units.Point) !void {
        if (self.current_point == null) return self.moveTo(point);
        try self.nodes.append(.{ .line_to = .{ .point = point } });
        self.current_point = point;
    }

    /// Draws a cubic bezier with the three supplied control points from
    /// the current point. The new current point is set to p3.
    ///
    /// It is an error to call this without a current point.
    pub fn curveTo(self: *PathOperation, p1: units.Point, p2: units.Point, p3: units.Point) !void {
        if (self.current_point == null) return error.PathOperationCurveToNoCurrentPoint;
        try self.nodes.append(.{ .curve_to = .{ .p1 = p1, .p2 = p2, .p3 = p3 } });
        self.current_point = p3;
    }

    /// Closes the path by drawing a line from the current point by the
    /// starting point. No effect if there is no current point.
    pub fn closePath(self: *PathOperation) !void {
        if (self.current_point == null) return;
        if (self.last_move_point) |last_move_point| {
            try self.nodes.append(.{ .close_path = .{} });

            // Add a move_to immediately after the close_path node. This is
            // explicit, to ensure that the state machine for draw operations
            // (fill, stroke) do not get put into an unreachable state.
            try self.moveTo(last_move_point);
        } else return error.PathOperationClosePathNoLastMovePoint;
    }

    /// Returns true if the path set is currently closed, meaning that the last
    /// operation called on the path set was closePath.
    ///
    /// This is used to check if a path is closed for filling, so it does not
    /// guarantee that any sub-paths that may be part of the set that precede
    /// the current path are closed as well.
    pub fn closed(self: *const PathOperation) bool {
        const len = self.nodes.items.len;
        if (len < 2) return false;
        return self.nodes.items[len - 2] == .close_path and self.nodes.items[len - 1] == .move_to;
    }
};
