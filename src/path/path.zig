//! Path is the "path builder" type, and contains a set of sub-paths used for
//! filling or stroking operations.
const std = @import("std");
const mem = @import("std").mem;

const units = @import("../units.zig");

const PathNode = @import("nodes.zig").PathNode;

const Path = @This();

/// The underlying node set.
nodes: std.ArrayList(PathNode),

/// The start of the current subpath when working with drawing operations.
initial_point: ?units.Point = null,

/// The current point when working with drawing operations.
current_point: ?units.Point = null,

/// Initializes the path operation. Call deinit to release the node list when
/// complete.
pub fn init(alloc: mem.Allocator) Path {
    return .{
        .nodes = std.ArrayList(PathNode).init(alloc),
    };
}

/// Releases the path node array list. It's invalid to use the operation after
/// this call.
pub fn deinit(self: *Path) void {
    self.nodes.deinit();
}

/// Rests the path operation, clearing all nodes and state.
pub fn reset(self: *Path) void {
    self.nodes.clearRetainingCapacity();
    self.initial_point = null;
    self.current_point = null;
}

/// Starts a new path, and moves the current point to it.
pub fn moveTo(self: *Path, point: units.Point) !void {
    // If our last operation is a move_to to this point, this is a no-op.
    // This ensures that there's no duplicates on things like explicit
    // definitions on close_path -> move_to (versus the implicit add in the
    // close operation).
    if (self.nodes.getLastOrNull()) |node| {
        switch (node) {
            .move_to => |move_to| {
                if (move_to.point.equal(point)) return;
            },
            else => {},
        }
    }

    try self.nodes.append(.{ .move_to = .{ .point = point } });
    self.initial_point = point;
    self.current_point = point;
}

/// Draws a line from the current point to the specified point and sets it as
/// the current point.
///
/// Acts as a moveTo instead if there is no current point.
pub fn lineTo(self: *Path, point: units.Point) !void {
    if (self.current_point == null) return self.moveTo(point);
    try self.nodes.append(.{ .line_to = .{ .point = point } });
    self.current_point = point;
}

/// Draws a cubic bezier with the three supplied control points from
/// the current point. The new current point is set to p3.
///
/// It is an error to call this without a current point.
pub fn curveTo(self: *Path, p1: units.Point, p2: units.Point, p3: units.Point) !void {
    if (self.current_point == null) return error.NoCurrentPoint;
    try self.nodes.append(.{ .curve_to = .{ .p1 = p1, .p2 = p2, .p3 = p3 } });
    self.current_point = p3;
}

/// Closes the path by drawing a line from the current point by the
/// starting point. No effect if there is no current point.
pub fn close(self: *Path) !void {
    if (self.current_point == null) return;
    if (self.initial_point) |initial_point| {
        try self.nodes.append(.{ .close_path = .{} });

        // Add a move_to immediately after the close_path node. This is
        // explicit, to ensure that the state machine for draw operations
        // (fill, stroke) do not get put into an unreachable state.
        try self.moveTo(initial_point);
    } else return error.NoInitialPoint;
}

/// Returns true if the path set is currently closed, meaning that the last
/// operation called on the path set was close.
///
/// This is used to check if a path is closed for filling, so it does not
/// guarantee that any sub-paths that may be part of the set that precede
/// the current path are closed as well.
pub fn isClosed(self: *const Path) bool {
    const len = self.nodes.items.len;
    if (len < 2) return false;
    return self.nodes.items[len - 2] == .close_path and self.nodes.items[len - 1] == .move_to;
}
