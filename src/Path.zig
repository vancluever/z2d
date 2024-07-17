// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024 Chris Marchesi

//! Path is the "path builder" type, and contains a set of sub-paths used for
//! filling or stroking operations.
const Path = @This();

const std = @import("std");
const math = @import("std").math;
const mem = @import("std").mem;
const testing = @import("std").testing;

const arcpkg = @import("internal/arc.zig");

const PathNode = @import("internal/path_nodes.zig").PathNode;
const Point = @import("internal/Point.zig");
const PathError = @import("errors.zig").PathError;

/// The underlying node set. Do not edit or populate this directly, use the
/// builder functions (e.g., moveTo, lineTo, curveTo, closePath, etc).
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

/// Begins a new sub-path relative to the current point. It is an error to call
/// this without a current point.
pub fn relMoveTo(self: *Path, x: f64, y: f64) !void {
    if (self.current_point) |p| {
        return self.moveTo(p.x + x, p.y + y);
    } else return PathError.NoCurrentPoint;
}

/// Draws a line from the current point to the specified point and sets it as
/// the current point. Acts as a `moveTo` instead if there is no current point.
pub fn lineTo(self: *Path, x: f64, y: f64) !void {
    if (self.current_point == null) return self.moveTo(x, y);
    const point: Point = .{ .x = clampI32(x), .y = clampI32(y) };
    try self.nodes.append(.{ .line_to = .{ .point = point } });
    self.current_point = point;
}

/// Draws a line relative to the current point. It is an error to call this
/// without a current point.
pub fn relLineTo(self: *Path, x: f64, y: f64) !void {
    if (self.current_point) |p| {
        return self.lineTo(p.x + x, p.y + y);
    } else return PathError.NoCurrentPoint;
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

/// Draws a cubic bezier relative to the current point. It is an error to call
/// this without a current point.
pub fn relCurveTo(
    self: *Path,
    x1: f64,
    y1: f64,
    x2: f64,
    y2: f64,
    x3: f64,
    y3: f64,
) !void {
    if (self.current_point) |p| {
        return self.curveTo(p.x + x1, p.y + y1, p.x + x2, p.y + y2, p.x + x3, p.y + y3);
    } else return PathError.NoCurrentPoint;
}

/// Adds a circular arc of the given radius to the current path. The arc is
/// centered at (xc, yc), begins at angle1 and proceeds in the direction of
/// increasing angles (if negative is false; i.e., counterclockwise direction)
/// or positive (if negative is true; i.e., counterclockwise direction) to end
/// at angle2.
///
/// If angle2 is less than angle1 and negative is false, it will be increased
/// by 2*Π until it's greater than angle1; If angle2 is greater than angle1 and
/// negative is true, it will be decreased by 2*Π until it's greater than
/// angle1.
///
/// Angles are measured at radians (to convert from degrees, multiply by Π /
/// 180).
///
/// If there's a current point, an initial line segment will be added to the
/// path to connect the current point to the beginning of the arc. If this
/// behavior is undesired, call `clear` before calling. This will trigger a
/// `moveTo` before the splines are plotted, creating a new subpath.
///
/// If you have changed tolerance in the context that will be acting on this
/// path, supply that value to tolerance; you can get the value from the
/// `tolerance` field in the context. Otherwise, use null, and the default
/// tolerance will be used.
///
/// After this operation, the current point will be the end of the arc.
pub fn arc(
    self: *Path,
    xc: f64,
    yc: f64,
    radius: f64,
    angle1: f64,
    angle2: f64,
    negative: bool,
    tolerance: ?f64,
) !void {
    if (negative) {
        var effective_angle2 = angle2;
        while (effective_angle2 > angle1) effective_angle2 -= math.pi * 2;
        try arcpkg.arc_in_direction(
            &.{
                .ptr = self,
                .line_to = arc_line_to,
                .curve_to = arc_curve_to,
            },
            xc,
            yc,
            radius,
            effective_angle2,
            angle1,
            .reverse,
            tolerance,
        );
    } else {
        var effective_angle2 = angle2;
        while (effective_angle2 < angle1) effective_angle2 += math.pi * 2;
        try arcpkg.arc_in_direction(
            &.{
                .ptr = self,
                .line_to = arc_line_to,
                .curve_to = arc_curve_to,
            },
            xc,
            yc,
            radius,
            angle1,
            effective_angle2,
            .forward,
            tolerance,
        );
    }
}

fn arc_line_to(
    ctx: *anyopaque,
    err_: *?anyerror,
    x: f64,
    y: f64,
) void {
    const self: *Path = @ptrCast(@alignCast(ctx));
    // no-op if our current point == destination. This is used to avoid drawing
    // artifacts for now on arcs, but if it's needed generally, we can
    // add it to lineTo proper itself.
    if (self.current_point) |p| {
        if (p.x == x and p.y == y) return;
    }
    self.lineTo(x, y) catch |err| {
        err_.* = err;
        return;
    };
}

fn arc_curve_to(
    ctx: *anyopaque,
    err_: *?anyerror,
    x1: f64,
    y1: f64,
    x2: f64,
    y2: f64,
    x3: f64,
    y3: f64,
) void {
    const self: *Path = @ptrCast(@alignCast(ctx));
    self.curveTo(x1, y1, x2, y2, x3, y3) catch |err| {
        err_.* = err;
        return;
    };
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

/// Returns true if all subpaths in the path set are currently closed.
pub fn isClosed(self: *const Path) bool {
    if (self.nodes.items.len == 0) return false;

    var closed = false;
    for (self.nodes.items, 0..) |node, i| {
        switch (node) {
            .move_to => if (!closed and i != 0) break,
            .close_path => closed = true,
            else => closed = false,
        }
    }

    return closed;
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

test "isClosed" {
    {
        // Basic (closed)
        var p = init(testing.allocator);
        defer p.deinit();
        try p.moveTo(1, 1);
        try p.lineTo(2, 2);
        try p.lineTo(3, 3);
        try p.close();
        try testing.expectEqual(true, p.isClosed());
    }

    {
        // Multiple subpaths, all closed
        var p = init(testing.allocator);
        defer p.deinit();
        try p.moveTo(1, 1);
        try p.lineTo(2, 2);
        try p.lineTo(3, 3);
        try p.close();
        try p.moveTo(4, 4);
        try p.lineTo(5, 5);
        try p.lineTo(6, 6);
        try p.close();
        try testing.expectEqual(true, p.isClosed());
    }

    {
        // Basic (not closed)
        var p = init(testing.allocator);
        defer p.deinit();
        try p.moveTo(1, 1);
        try p.lineTo(2, 2);
        try p.moveTo(3, 3);
        try p.lineTo(4, 4);
        try p.lineTo(5, 5);
        try testing.expectEqual(false, p.isClosed());
    }

    {
        // Closed in the middle
        var p = init(testing.allocator);
        defer p.deinit();
        try p.moveTo(1, 1);
        try p.lineTo(2, 2);
        try p.close();
        try p.moveTo(3, 3);
        try p.lineTo(4, 4);
        try p.lineTo(5, 5);
        try testing.expectEqual(false, p.isClosed());
    }

    {
        // Closed at the end (not in the middle)
        var p = init(testing.allocator);
        defer p.deinit();
        try p.moveTo(1, 1);
        try p.lineTo(2, 2);
        try p.moveTo(3, 3);
        try p.lineTo(4, 4);
        try p.lineTo(5, 5);
        try p.close();
        try testing.expectEqual(false, p.isClosed());
    }

    {
        // Empty node set
        var p = init(testing.allocator);
        defer p.deinit();
        try testing.expectEqual(false, p.isClosed());
    }
}

test "relMoveTo" {
    {
        // Normal
        var p = init(testing.allocator);
        defer p.deinit();
        try p.moveTo(1, 1);
        try p.relMoveTo(1, 1);
        try testing.expectEqual(PathNode{ .move_to = .{ .point = .{ .x = 1, .y = 1 } } }, p.nodes.items[0]);
        try testing.expectEqual(PathNode{ .move_to = .{ .point = .{ .x = 2, .y = 2 } } }, p.nodes.items[1]);
        try testing.expectEqual(Point{ .x = 2, .y = 2 }, p.initial_point);
        try testing.expectEqual(Point{ .x = 2, .y = 2 }, p.current_point);
    }

    {
        // Reverse
        var p = init(testing.allocator);
        defer p.deinit();
        try p.moveTo(1, 1);
        try p.relMoveTo(-10, -10);
        try testing.expectEqual(PathNode{ .move_to = .{ .point = .{ .x = 1, .y = 1 } } }, p.nodes.items[0]);
        try testing.expectEqual(PathNode{ .move_to = .{ .point = .{ .x = -9, .y = -9 } } }, p.nodes.items[1]);
        try testing.expectEqual(Point{ .x = -9, .y = -9 }, p.initial_point);
        try testing.expectEqual(Point{ .x = -9, .y = -9 }, p.current_point);
    }

    {
        // No current point
        var p = init(testing.allocator);
        defer p.deinit();
        try testing.expectEqual(PathError.NoCurrentPoint, p.relMoveTo(1, 1));
    }
}

test "relLineTo" {
    {
        // Normal
        var p = init(testing.allocator);
        defer p.deinit();
        try p.moveTo(1, 1);
        try p.relLineTo(1, 1);
        try testing.expectEqual(PathNode{ .move_to = .{ .point = .{ .x = 1, .y = 1 } } }, p.nodes.items[0]);
        try testing.expectEqual(PathNode{ .line_to = .{ .point = .{ .x = 2, .y = 2 } } }, p.nodes.items[1]);
        try testing.expectEqual(Point{ .x = 1, .y = 1 }, p.initial_point);
        try testing.expectEqual(Point{ .x = 2, .y = 2 }, p.current_point);
    }

    {
        // Reverse
        var p = init(testing.allocator);
        defer p.deinit();
        try p.moveTo(1, 1);
        try p.relLineTo(-10, -10);
        try testing.expectEqual(PathNode{ .move_to = .{ .point = .{ .x = 1, .y = 1 } } }, p.nodes.items[0]);
        try testing.expectEqual(PathNode{ .line_to = .{ .point = .{ .x = -9, .y = -9 } } }, p.nodes.items[1]);
        try testing.expectEqual(Point{ .x = 1, .y = 1 }, p.initial_point);
        try testing.expectEqual(Point{ .x = -9, .y = -9 }, p.current_point);
    }

    {
        // No current point
        var p = init(testing.allocator);
        defer p.deinit();
        try testing.expectEqual(PathError.NoCurrentPoint, p.relLineTo(1, 1));
    }
}

test "relCurveTo" {
    {
        // Normal
        var p = init(testing.allocator);
        defer p.deinit();
        try p.moveTo(1, 1);
        try p.relCurveTo(1, 1, 2, 2, 3, 3);
        try testing.expectEqual(PathNode{ .move_to = .{ .point = .{ .x = 1, .y = 1 } } }, p.nodes.items[0]);
        try testing.expectEqual(PathNode{
            .curve_to = .{
                .p1 = .{ .x = 2, .y = 2 },
                .p2 = .{ .x = 3, .y = 3 },
                .p3 = .{ .x = 4, .y = 4 },
            },
        }, p.nodes.items[1]);
        try testing.expectEqual(Point{ .x = 1, .y = 1 }, p.initial_point);
        try testing.expectEqual(Point{ .x = 4, .y = 4 }, p.current_point);
    }

    {
        // Reverse
        var p = init(testing.allocator);
        defer p.deinit();
        try p.moveTo(1, 1);
        try p.relCurveTo(-10, -10, -11, -11, -12, -12);
        try testing.expectEqual(PathNode{ .move_to = .{ .point = .{ .x = 1, .y = 1 } } }, p.nodes.items[0]);
        try testing.expectEqual(PathNode{
            .curve_to = .{
                .p1 = .{ .x = -9, .y = -9 },
                .p2 = .{ .x = -10, .y = -10 },
                .p3 = .{ .x = -11, .y = -11 },
            },
        }, p.nodes.items[1]);
        try testing.expectEqual(Point{ .x = 1, .y = 1 }, p.initial_point);
        try testing.expectEqual(Point{ .x = -11, .y = -11 }, p.current_point);
    }

    {
        // No current point
        var p = init(testing.allocator);
        defer p.deinit();
        try testing.expectEqual(PathError.NoCurrentPoint, p.relCurveTo(1, 1, 2, 2, 3, 3));
    }
}
