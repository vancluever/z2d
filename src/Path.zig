// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024 Chris Marchesi

//! Path is the "path builder" type, and contains a set of sub-paths used for
//! filling or stroking operations.
const Path = @This();

const std = @import("std");
const math = @import("std").math;
const mem = @import("std").mem;
const testing = @import("std").testing;

const PathNode = @import("internal/path_nodes.zig").PathNode;
const Point = @import("internal/Point.zig");
const PathError = @import("errors.zig").PathError;

/// The underlying node set.
nodes: std.ArrayList(PathNode),

/// The start of the current subpath when working with drawing operations.
initial_point: ?Point = null,

/// The current point when working with drawing operations.
current_point: ?Point = null,

/// Initializes the path set. Call deinit to release the node list when
/// complete.
pub fn init(alloc: mem.Allocator) Path {
    return .{
        .nodes = std.ArrayList(PathNode).init(alloc),
    };
}

/// Releases the path node array list. It's invalid to use the path set after
/// this call.
pub fn deinit(self: *Path) void {
    self.nodes.deinit();
}

/// Rests the path set, clearing all nodes and state.
pub fn reset(self: *Path) void {
    self.nodes.clearRetainingCapacity();
    self.initial_point = null;
    self.current_point = null;
}

/// Starts a new path, and moves the current point to it.
pub fn moveTo(self: *Path, x: f64, y: f64) !void {
    const point: Point = .{ .x = clampI32(x), .y = clampI32(y) };
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
/// the current point. Acts as a `moveTo` instead if there is no current point.
pub fn lineTo(self: *Path, x: f64, y: f64) !void {
    if (self.current_point == null) return self.moveTo(x, y);
    const point: Point = .{ .x = clampI32(x), .y = clampI32(y) };
    try self.nodes.append(.{ .line_to = .{ .point = point } });
    self.current_point = point;
}

/// Draws a cubic bezier with the three supplied control points from the
/// current point. The new current point is set to (x3, y3). It is an error to
/// call this without a current point.
pub fn curveTo(
    self: *Path,
    x1: f64,
    y1: f64,
    x2: f64,
    y2: f64,
    x3: f64,
    y3: f64,
) !void {
    if (self.current_point == null) return PathError.NoCurrentPoint;
    const p1: Point = .{ .x = clampI32(x1), .y = clampI32(y1) };
    const p2: Point = .{ .x = clampI32(x2), .y = clampI32(y2) };
    const p3: Point = .{ .x = clampI32(x3), .y = clampI32(y3) };
    try self.nodes.append(.{ .curve_to = .{ .p1 = p1, .p2 = p2, .p3 = p3 } });
    self.current_point = p3;
}

/// Closes the path by drawing a line from the current point by the starting
/// point. No effect if there is no current point.
pub fn close(self: *Path) !void {
    if (self.current_point == null) return;
    if (self.initial_point) |initial_point| {
        try self.nodes.append(.{ .close_path = .{} });

        // Add a move_to immediately after the close_path node. This is
        // explicit, to ensure that the state machine for draw operations
        // (fill, stroke) do not get put into an unreachable state.
        try self.moveTo(initial_point.x, initial_point.y);
    } else return PathError.NoInitialPoint;
}

/// Returns true if the path set is currently closed, meaning that the last
/// operation called on the path set was `close`.
///
/// This is used to check if a path is closed for filling, so it does not
/// guarantee that any sub-paths that may be part of the set that precede
/// the current path are closed as well.
pub fn isClosed(self: *const Path) bool {
    const len = self.nodes.items.len;
    if (len < 2) return false;
    return self.nodes.items[len - 2] == .close_path and self.nodes.items[len - 1] == .move_to;
}

fn clampI32(x: f64) f64 {
    return math.clamp(x, math.minInt(i32), math.maxInt(i32));
}

test "moveTo clamped" {
    {
        // Normal
        var p = init(testing.allocator);
        defer p.deinit();
        try p.moveTo(1, 2);
        try testing.expectEqual(PathNode{ .move_to = .{ .point = .{ .x = 1, .y = 2 } } }, p.nodes.items[0]);
        try testing.expectEqual(Point{ .x = 1, .y = 2 }, p.initial_point);
        try testing.expectEqual(Point{ .x = 1, .y = 2 }, p.current_point);
    }
    {
        // Clamped
        var p = init(testing.allocator);
        defer p.deinit();
        try p.moveTo(math.minInt(i32) - 1, math.maxInt(i32) + 1);
        try testing.expectEqual(PathNode{
            .move_to = .{ .point = .{ .x = math.minInt(i32), .y = math.maxInt(i32) } },
        }, p.nodes.items[0]);
        try testing.expectEqual(Point{ .x = math.minInt(i32), .y = math.maxInt(i32) }, p.initial_point);
        try testing.expectEqual(Point{ .x = math.minInt(i32), .y = math.maxInt(i32) }, p.current_point);
    }
}

test "lineTo clamped" {
    {
        // Normal
        var p = init(testing.allocator);
        defer p.deinit();
        try p.moveTo(1, 1);
        try p.lineTo(1, 2);
        try testing.expectEqual(PathNode{ .line_to = .{ .point = .{ .x = 1, .y = 2 } } }, p.nodes.items[1]);
        try testing.expectEqual(Point{ .x = 1, .y = 1 }, p.initial_point);
        try testing.expectEqual(Point{ .x = 1, .y = 2 }, p.current_point);
    }
    {
        // Clamped
        var p = init(testing.allocator);
        defer p.deinit();
        try p.moveTo(1, 1);
        try p.lineTo(math.minInt(i32) - 1, math.maxInt(i32) + 1);
        try testing.expectEqual(PathNode{
            .line_to = .{ .point = .{ .x = math.minInt(i32), .y = math.maxInt(i32) } },
        }, p.nodes.items[1]);
        try testing.expectEqual(Point{ .x = 1, .y = 1 }, p.initial_point);
        try testing.expectEqual(Point{ .x = math.minInt(i32), .y = math.maxInt(i32) }, p.current_point);
    }
}

test "curveTo clamped" {
    {
        // Normal
        var p = init(testing.allocator);
        defer p.deinit();
        try p.moveTo(1, 1);
        try p.curveTo(1, 2, 3, 4, 5, 6);
        try testing.expectEqual(PathNode{
            .curve_to = .{
                .p1 = .{ .x = 1, .y = 2 },
                .p2 = .{ .x = 3, .y = 4 },
                .p3 = .{ .x = 5, .y = 6 },
            },
        }, p.nodes.items[1]);
        try testing.expectEqual(Point{ .x = 1, .y = 1 }, p.initial_point);
        try testing.expectEqual(Point{ .x = 5, .y = 6 }, p.current_point);
    }
    {
        // Clamped
        var p = init(testing.allocator);
        defer p.deinit();
        try p.moveTo(1, 1);
        try p.curveTo(math.minInt(i32) - 1, math.maxInt(i32) + 1, 3, 4, 5, 6);
        try testing.expectEqual(PathNode{
            .curve_to = .{
                .p1 = .{
                    .x = math.minInt(i32),
                    .y = math.maxInt(i32),
                },
                .p2 = .{ .x = 3, .y = 4 },
                .p3 = .{ .x = 5, .y = 6 },
            },
        }, p.nodes.items[1]);
        try testing.expectEqual(Point{ .x = 1, .y = 1 }, p.initial_point);
        try testing.expectEqual(Point{ .x = 5, .y = 6 }, p.current_point);
        try p.curveTo(1, 2, math.minInt(i32) - 1, math.maxInt(i32) + 1, 5, 6);
        try testing.expectEqual(PathNode{
            .curve_to = .{
                .p1 = .{ .x = 1, .y = 2 },
                .p2 = .{
                    .x = math.minInt(i32),
                    .y = math.maxInt(i32),
                },
                .p3 = .{ .x = 5, .y = 6 },
            },
        }, p.nodes.items[2]);
        try testing.expectEqual(Point{ .x = 1, .y = 1 }, p.initial_point);
        try testing.expectEqual(Point{ .x = 5, .y = 6 }, p.current_point);
        try p.curveTo(1, 2, 3, 4, math.minInt(i32) - 1, math.maxInt(i32) + 1);
        try testing.expectEqual(PathNode{
            .curve_to = .{
                .p1 = .{ .x = 1, .y = 2 },
                .p2 = .{ .x = 3, .y = 4 },
                .p3 = .{
                    .x = math.minInt(i32),
                    .y = math.maxInt(i32),
                },
            },
        }, p.nodes.items[3]);
        try testing.expectEqual(Point{ .x = 1, .y = 1 }, p.initial_point);
        try testing.expectEqual(Point{ .x = math.minInt(i32), .y = math.maxInt(i32) }, p.current_point);
    }
}
