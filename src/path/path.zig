const std = @import("std");
const mem = @import("std").mem;

const contextpkg = @import("../context.zig");
const fillerpkg = @import("filler.zig");
const nodepkg = @import("nodes.zig");
const polypkg = @import("polygon.zig");
const units = @import("../units.zig");

/// A path drawing operation, resulting in a rendered complex set of one or
/// more polygons.
pub const PathOperation = struct {
    // The allocator used for various tasks over the lifetime of the operation
    // (filling, stroking, etc).
    alloc: mem.Allocator,

    /// A reference back to the draw context.
    ///
    /// private: should not be edited directly.
    context: *contextpkg.DrawContext,

    /// The set of path nodes.
    ///
    /// private: should not be edited directly.
    nodes: std.ArrayList(nodepkg.PathNode),

    /// The start of the current subpath when working with drawing
    /// operations.
    ///
    /// private: should not be edited directly.
    last_move_point: ?units.Point = null,

    /// The current point when working with drawing operations.
    ///
    /// private: should not be edited directly.
    current_point: ?units.Point = null,

    /// Initializes the path operation. Call deinit to release the node
    /// list when complete.
    pub fn init(alloc: mem.Allocator, context: *contextpkg.DrawContext) PathOperation {
        return .{
            .alloc = alloc,
            .context = context,
            .nodes = std.ArrayList(nodepkg.PathNode).init(alloc),
        };
    }

    /// Releases the path node array list. It's invalid to use the
    /// operation after this call.
    pub fn deinit(self: *PathOperation) void {
        self.nodes.deinit();
    }

    /// Starts a new path, and moves the current point to it.
    pub fn moveTo(self: *PathOperation, point: units.Point) !void {
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
        if (self.last_move_point == null) return error.PathOperationClosePathNoLastMovePoint;
        try self.nodes.append(.{ .close_path = .{} });

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
        try fillerpkg.fill(self.alloc, &self.nodes, self.context.surface, self.context.pattern);
    }
};
