// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024-2025 Chris Marchesi

//! Path is the "path builder" type, and contains a set of sub-paths used for
//! filling or stroking operations.
//!
//! Paths can be initialized via:
//!
//! * An empty value, or using `initCapacity` - when done this way, you must
//! use the methods that take an allocator (e.g., `moveTo`) and call `deinit`
//! when done. Note that the same allocator needs to be used for the lifetime
//! of the path.
//!
//! * By using `initBuffer` and the methods that do not take an allocator
//! (e.g., `moveToAssumeCapacity`). Using this method, you manage the node
//! memory manually and `deinit` should not be called.
//!
//! A `Context` contains a managed `Path`, and you only need to use this
//! package directly if you are not using it.
//!
//! You may also be interested in `StaticPath`, which is an infallible wrapper
//! over the static buffer-managed pattern that you would get by using
//! `initBuffer` here.
const Path = @This();

const std = @import("std");
const debug = @import("std").debug;
const math = @import("std").math;
const mem = @import("std").mem;
const testing = @import("std").testing;

const arcpkg = @import("internal/arc.zig");
const options = @import("options.zig");

const PathNode = @import("internal/path_nodes.zig").PathNode;
const PathVTable = @import("internal/PathVTable.zig");
const Point = @import("internal/Point.zig");
const Transformation = @import("Transformation.zig");

/// Errors associated with `Path` point plotting operations.
pub const Error = error{
    /// A path operation requires a current point, but does not have one.
    NoCurrentPoint,

    /// A relative path helper encountered an error inverting the current
    /// transformation matrix to translate the current point back to user space
    /// before applying the relative point. This is necessary as path nodes are
    /// stored in device space at the lower level. Make sure any transformation
    /// matrices in use are invertible and use the standard helpers (translate,
    /// rotate, scale) unless absolutely necessary.
    InvalidMatrix,
};

/// The underlying node set. Do not edit or populate this directly, use the
/// builder functions (e.g., `moveTo`, `lineTo`, `curveTo`, `close`, etc).
nodes: std.ArrayListUnmanaged(PathNode) = .empty,

/// The start of the current subpath when working with drawing operations.
initial_point: ?Point = null,

/// The current point when working with drawing operations.
current_point: ?Point = null,

/// The tolerance setting used when approximating arcs as splines. For more
/// detail on this setting, see its counterpart in `Context`.
tolerance: f64 = options.default_tolerance,

/// The current transformation matrix (CTM) for this path.
///
/// When adding points to a path, the co-ordinates are mapped with whatever the
/// CTM is set to at call-time. This allows for certain parts of a path to be
/// drawn with a matrix, and then the matrix to be modified or restored to
/// allow for normal drawing to continue.
///
/// The default CTM is the identity matrix (i.e., 1:1 with user space and
/// device space).
transformation: Transformation = Transformation.identity,

/// Represents an empty `Path`.
pub const empty: Path = .{};

/// Initializes the path set with an initial capacity of exactly `num`. Call
/// `deinit` to release the node list when complete.
pub fn initCapacity(alloc: mem.Allocator, num: usize) mem.Allocator.Error!Path {
    return .{
        .nodes = try std.ArrayListUnmanaged(PathNode).initCapacity(alloc, num),
    };
}

/// Initializes a `Path` with externally allocated memory. If you use this over
/// `initCapacity`, do not use any method that takes an allocator as it will be
/// an illegal operation.
pub fn initBuffer(nodes: []PathNode) Path {
    return .{
        .nodes = std.ArrayListUnmanaged(PathNode).initBuffer(nodes),
    };
}

/// Releases the `Path`'s node array list. It's invalid to use the path set
/// after this call.
pub fn deinit(self: *Path, alloc: mem.Allocator) void {
    self.nodes.deinit(alloc);
}

/// Rests the path set, clearing all nodes and state.
pub fn reset(self: *Path) void {
    self.nodes.clearRetainingCapacity();
    self.initial_point = null;
    self.current_point = null;
}

/// Starts a new path, and moves the current point to it.
pub fn moveTo(self: *Path, alloc: mem.Allocator, x: f64, y: f64) mem.Allocator.Error!void {
    const newlen = self.nodes.items.len + 1;
    try self.nodes.ensureTotalCapacity(alloc, newlen);
    self.moveToAssumeCapacity(x, y);
}

/// Like `moveTo`, but does not require an allocator. Assumes enough space
/// exists for the point.
pub fn moveToAssumeCapacity(self: *Path, x: f64, y: f64) void {
    const point: Point = (Point{
        .x = clampI32(x),
        .y = clampI32(y),
    }).applyTransform(self.transformation);
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

    self.nodes.appendAssumeCapacity(.{ .move_to = .{ .point = point } });
    self.initial_point = point;
    self.current_point = point;
}

/// Begins a new sub-path relative to the current point. It is an error to call
/// this without a current point.
pub fn relMoveTo(self: *Path, alloc: mem.Allocator, x: f64, y: f64) (Error || mem.Allocator.Error)!void {
    if (self.current_point) |p| {
        const user_point = try p.applyInverseTransform(self.transformation);
        return self.moveTo(alloc, user_point.x + x, user_point.y + y);
    } else return error.NoCurrentPoint;
}

/// Like `relMoveTo`, but does not require an allocator. Assumes enough space
/// exists for the point.
pub fn relMoveToAssumeCapacity(self: *Path, x: f64, y: f64) Error!void {
    if (self.current_point) |p| {
        const user_point = try p.applyInverseTransform(self.transformation);
        self.moveToAssumeCapacity(user_point.x + x, user_point.y + y);
    } else return error.NoCurrentPoint;
}

/// Draws a line from the current point to the specified point and sets it as
/// the current point. Acts as a `moveTo` instead if there is no current point.
pub fn lineTo(self: *Path, alloc: mem.Allocator, x: f64, y: f64) mem.Allocator.Error!void {
    const newlen = self.nodes.items.len + 1;
    try self.nodes.ensureTotalCapacity(alloc, newlen);
    self.lineToAssumeCapacity(x, y);
}

/// Like `lineTo`, but does not require an allocator. Assumes enough space
/// exists for the point.
pub fn lineToAssumeCapacity(self: *Path, x: f64, y: f64) void {
    if (self.current_point == null) return self.moveToAssumeCapacity(x, y);
    const point: Point = (Point{
        .x = clampI32(x),
        .y = clampI32(y),
    }).applyTransform(self.transformation);
    self.nodes.appendAssumeCapacity(.{ .line_to = .{ .point = point } });
    self.current_point = point;
}

/// Draws a line relative to the current point. It is an error to call this
/// without a current point.
pub fn relLineTo(self: *Path, alloc: mem.Allocator, x: f64, y: f64) (Error || mem.Allocator.Error)!void {
    if (self.current_point) |p| {
        const user_point = try p.applyInverseTransform(self.transformation);
        return self.lineTo(alloc, user_point.x + x, user_point.y + y);
    } else return error.NoCurrentPoint;
}

/// Like `relLineTo`, but does not require an allocator. Assumes enough space
/// exists for the point.
pub fn relLineToAssumeCapacity(self: *Path, x: f64, y: f64) Error!void {
    if (self.current_point) |p| {
        const user_point = try p.applyInverseTransform(self.transformation);
        self.lineToAssumeCapacity(user_point.x + x, user_point.y + y);
    } else return error.NoCurrentPoint;
}

/// Draws a cubic bezier with the three supplied control points from the
/// current point. The new current point is set to (`x3`, `y3`). It is an error
/// to call this without a current point.
pub fn curveTo(
    self: *Path,
    alloc: mem.Allocator,
    x1: f64,
    y1: f64,
    x2: f64,
    y2: f64,
    x3: f64,
    y3: f64,
) (Error || mem.Allocator.Error)!void {
    if (self.current_point == null) return error.NoCurrentPoint;
    const newlen = self.nodes.items.len + 1;
    try self.nodes.ensureTotalCapacity(alloc, newlen);
    self._curveToAssumeCapacity(x1, y1, x2, y2, x3, y3);
}

/// Like `curveTo`, but does not require an allocator. Assumes enough space
/// exists for the point.
pub fn curveToAssumeCapacity(
    self: *Path,
    x1: f64,
    y1: f64,
    x2: f64,
    y2: f64,
    x3: f64,
    y3: f64,
) Error!void {
    if (self.current_point == null) return error.NoCurrentPoint;
    self._curveToAssumeCapacity(x1, y1, x2, y2, x3, y3);
}

fn _curveToAssumeCapacity(
    self: *Path,
    x1: f64,
    y1: f64,
    x2: f64,
    y2: f64,
    x3: f64,
    y3: f64,
) void {
    const p1: Point = (Point{
        .x = clampI32(x1),
        .y = clampI32(y1),
    }).applyTransform(self.transformation);
    const p2: Point = (Point{
        .x = clampI32(x2),
        .y = clampI32(y2),
    }).applyTransform(self.transformation);
    const p3: Point = (Point{
        .x = clampI32(x3),
        .y = clampI32(y3),
    }).applyTransform(self.transformation);
    self.nodes.appendAssumeCapacity(.{ .curve_to = .{ .p1 = p1, .p2 = p2, .p3 = p3 } });
    self.current_point = p3;
}

/// Draws a cubic bezier relative to the current point. It is an error to call
/// this without a current point.
pub fn relCurveTo(
    self: *Path,
    alloc: mem.Allocator,
    x1: f64,
    y1: f64,
    x2: f64,
    y2: f64,
    x3: f64,
    y3: f64,
) (Error || mem.Allocator.Error)!void {
    if (self.current_point) |p| {
        const user_point = try p.applyInverseTransform(self.transformation);
        return self.curveTo(
            alloc,
            user_point.x + x1,
            user_point.y + y1,
            user_point.x + x2,
            user_point.y + y2,
            user_point.x + x3,
            user_point.y + y3,
        );
    } else return error.NoCurrentPoint;
}

/// Like `relCurveTo`, but does not require an allocator. Assumes enough space
/// exists for the point.
pub fn relCurveToAssumeCapacity(
    self: *Path,
    x1: f64,
    y1: f64,
    x2: f64,
    y2: f64,
    x3: f64,
    y3: f64,
) Error!void {
    if (self.current_point) |p| {
        const user_point = try p.applyInverseTransform(self.transformation);
        return self.curveToAssumeCapacity(
            user_point.x + x1,
            user_point.y + y1,
            user_point.x + x2,
            user_point.y + y2,
            user_point.x + x3,
            user_point.y + y3,
        );
    } else return error.NoCurrentPoint;
}

/// Adds a circular arc of the given radius to the current path. The arc is
/// centered at (`xc`, `yc`), begins at `angle1` and proceeds in the direction
/// of increasing angles (i.e., counterclockwise direction) to end at `angle2`.
///
/// If `angle2` is less than `angle1`, it will be increased by 2 * Π until it's
/// greater than `angle1`.
///
/// Angles are measured at radians (to convert from degrees, multiply by Π /
/// 180).
///
/// If there's a current point, an initial line segment will be added to the
/// path to connect the current point to the beginning of the arc. If this
/// behavior is undesired, call `reset` before calling. This will trigger a
/// `moveTo` before the splines are plotted, creating a new subpath.
///
/// After this operation, the current point will be the end of the arc.
///
/// ## Drawing an ellipse
///
/// In order to draw an ellipse, use `arc` along with a transformation. The
/// following example will draw an elliptical arc at (`x`, `y`) bounded by the
/// rectangle of `width` by `height` (i.e., the rectangle controls the lengths
/// of the radii).
///
/// ```
/// const saved_ctm = path.transformation;
/// path.transformation = path.transformation
///     .translate(x + width / 2, y + height / 2);
///     .scale(width / 2, height / 2);
/// try path.arc(alloc, 0, 0, 1, 0, 2 + math.pi);
/// path.transformation = saved_ctm;
/// ```
///
pub fn arc(
    self: *Path,
    alloc: mem.Allocator,
    xc: f64,
    yc: f64,
    radius: f64,
    angle1: f64,
    angle2: f64,
) (Error || mem.Allocator.Error)!void {
    var effective_angle2 = angle2;
    while (effective_angle2 < angle1) effective_angle2 += math.pi * 2;
    try arcpkg.arc_in_direction(
        &.{
            .ptr = self,
            .alloc = alloc,
            .line_to = arc_line_to,
            .curve_to = arc_curve_to,
        },
        xc,
        yc,
        radius,
        angle1,
        effective_angle2,
        .forward,
        self.transformation,
        @max(self.tolerance, 0.001),
    );
}

/// Like `arc`, but draws in the reverse direction, i.e., begins at `angle1`,
/// and moves in decreasing angles (i.e., counterclockwise direction) to end at
/// `angle2`. If `angle2` is greater than `angle1`, it will be decreased by 2 *
/// Π until it's less than `angle1`.
pub fn arcNegative(
    self: *Path,
    alloc: mem.Allocator,
    xc: f64,
    yc: f64,
    radius: f64,
    angle1: f64,
    angle2: f64,
) (Error || mem.Allocator.Error)!void {
    var effective_angle2 = angle2;
    while (effective_angle2 > angle1) effective_angle2 -= math.pi * 2;
    try arcpkg.arc_in_direction(
        &.{
            .ptr = self,
            .alloc = alloc,
            .line_to = arc_line_to,
            .curve_to = arc_curve_to,
        },
        xc,
        yc,
        radius,
        effective_angle2,
        angle1,
        .reverse,
        self.transformation,
        @max(self.tolerance, 0.001),
    );
}

fn arc_line_to(
    ctx: *anyopaque,
    alloc: mem.Allocator,
    err_: *?mem.Allocator.Error,
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
    self.lineTo(alloc, x, y) catch |err| {
        err_.* = err;
        return;
    };
}

fn arc_curve_to(
    ctx: *anyopaque,
    alloc: mem.Allocator,
    err_: *?PathVTable.Error,
    x1: f64,
    y1: f64,
    x2: f64,
    y2: f64,
    x3: f64,
    y3: f64,
) void {
    const self: *Path = @ptrCast(@alignCast(ctx));
    self.curveTo(alloc, x1, y1, x2, y2, x3, y3) catch |err| {
        err_.* = err;
        return;
    };
}

/// Closes the path by drawing a line from the current point by the starting
/// point. No effect if there is no current point.
pub fn close(self: *Path, alloc: mem.Allocator) mem.Allocator.Error!void {
    if (self.current_point == null) return;
    debug.assert(self.initial_point != null);
    const newlen = self.nodes.items.len + 2;
    try self.nodes.ensureTotalCapacity(alloc, newlen);
    self._closeAssumeCapacity();
}

/// Like `close`, but does not require an allocator. Assumes enough space
/// exists for the points.
///
/// Note that path closes require two points, one for the `close_path` entry,
/// and one for the implicit `move_to` entry; ensure your `Path` has enough
/// space for both.
pub fn closeAssumeCapacity(self: *Path) void {
    if (self.current_point == null) return;
    debug.assert(self.initial_point != null);
    self._closeAssumeCapacity();
}

fn _closeAssumeCapacity(self: *Path) void {
    self.nodes.appendAssumeCapacity(.{ .close_path = .{} });

    // Add a move_to immediately after the close_path node. This is
    // explicit, to ensure that the state machine for draw operations
    // (fill, stroke) do not get put into an unreachable state.
    self.nodes.appendAssumeCapacity(.{ .move_to = .{
        .point = .{ .x = self.initial_point.?.x, .y = self.initial_point.?.y },
    } });
}

/// Returns `true` if all subpaths in the path set are currently closed.
pub fn isClosed(self: *const Path) bool {
    return PathNode.isClosedNodeSet(self.nodes.items);
}

fn clampI32(x: f64) f64 {
    return math.clamp(x, math.minInt(i32), math.maxInt(i32));
}

test "moveTo clamped" {
    const alloc = testing.allocator;
    {
        // Normal
        var p = try initCapacity(alloc, 0);
        defer p.deinit(alloc);
        try p.moveTo(alloc, 1, 2);
        try testing.expectEqual(PathNode{ .move_to = .{ .point = .{ .x = 1, .y = 2 } } }, p.nodes.items[0]);
        try testing.expectEqual(Point{ .x = 1, .y = 2 }, p.initial_point);
        try testing.expectEqual(Point{ .x = 1, .y = 2 }, p.current_point);
    }
    {
        // Clamped
        var p = try initCapacity(alloc, 0);
        defer p.deinit(alloc);
        try p.moveTo(alloc, math.minInt(i32) - 1, math.maxInt(i32) + 1);
        try testing.expectEqual(PathNode{
            .move_to = .{ .point = .{ .x = math.minInt(i32), .y = math.maxInt(i32) } },
        }, p.nodes.items[0]);
        try testing.expectEqual(Point{ .x = math.minInt(i32), .y = math.maxInt(i32) }, p.initial_point);
        try testing.expectEqual(Point{ .x = math.minInt(i32), .y = math.maxInt(i32) }, p.current_point);
    }
}

test "lineTo clamped" {
    const alloc = testing.allocator;
    {
        // Normal
        var p = try initCapacity(alloc, 0);
        defer p.deinit(alloc);
        try p.moveTo(alloc, 1, 1);
        try p.lineTo(alloc, 1, 2);
        try testing.expectEqual(PathNode{ .line_to = .{ .point = .{ .x = 1, .y = 2 } } }, p.nodes.items[1]);
        try testing.expectEqual(Point{ .x = 1, .y = 1 }, p.initial_point);
        try testing.expectEqual(Point{ .x = 1, .y = 2 }, p.current_point);
    }
    {
        // Clamped
        var p = try initCapacity(alloc, 0);
        defer p.deinit(alloc);
        try p.moveTo(alloc, 1, 1);
        try p.lineTo(alloc, math.minInt(i32) - 1, math.maxInt(i32) + 1);
        try testing.expectEqual(PathNode{
            .line_to = .{ .point = .{ .x = math.minInt(i32), .y = math.maxInt(i32) } },
        }, p.nodes.items[1]);
        try testing.expectEqual(Point{ .x = 1, .y = 1 }, p.initial_point);
        try testing.expectEqual(Point{ .x = math.minInt(i32), .y = math.maxInt(i32) }, p.current_point);
    }
}

test "curveTo clamped" {
    const alloc = testing.allocator;
    {
        // Normal
        var p = try initCapacity(alloc, 0);
        defer p.deinit(alloc);
        try p.moveTo(alloc, 1, 1);
        try p.curveTo(alloc, 1, 2, 3, 4, 5, 6);
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
        var p = try initCapacity(alloc, 0);
        defer p.deinit(alloc);
        try p.moveTo(alloc, 1, 1);
        try p.curveTo(alloc, math.minInt(i32) - 1, math.maxInt(i32) + 1, 3, 4, 5, 6);
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
        try p.curveTo(alloc, 1, 2, math.minInt(i32) - 1, math.maxInt(i32) + 1, 5, 6);
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
        try p.curveTo(alloc, 1, 2, 3, 4, math.minInt(i32) - 1, math.maxInt(i32) + 1);
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
    const alloc = testing.allocator;
    {
        // Basic (closed)
        var p = try initCapacity(alloc, 0);
        defer p.deinit(alloc);
        try p.moveTo(alloc, 1, 1);
        try p.lineTo(alloc, 2, 2);
        try p.lineTo(alloc, 3, 3);
        try p.close(alloc);
        try testing.expectEqual(true, p.isClosed());
    }

    {
        // Multiple subpaths, all closed
        var p = try initCapacity(alloc, 0);
        defer p.deinit(alloc);
        try p.moveTo(alloc, 1, 1);
        try p.lineTo(alloc, 2, 2);
        try p.lineTo(alloc, 3, 3);
        try p.close(alloc);
        try p.moveTo(alloc, 4, 4);
        try p.lineTo(alloc, 5, 5);
        try p.lineTo(alloc, 6, 6);
        try p.close(alloc);
        try testing.expectEqual(true, p.isClosed());
    }

    {
        // Basic (not closed)
        var p = try initCapacity(alloc, 0);
        defer p.deinit(alloc);
        try p.moveTo(alloc, 1, 1);
        try p.lineTo(alloc, 2, 2);
        try p.moveTo(alloc, 3, 3);
        try p.lineTo(alloc, 4, 4);
        try p.lineTo(alloc, 5, 5);
        try testing.expectEqual(false, p.isClosed());
    }

    {
        // Closed in the middle
        var p = try initCapacity(alloc, 0);
        defer p.deinit(alloc);
        try p.moveTo(alloc, 1, 1);
        try p.lineTo(alloc, 2, 2);
        try p.close(alloc);
        try p.moveTo(alloc, 3, 3);
        try p.lineTo(alloc, 4, 4);
        try p.lineTo(alloc, 5, 5);
        try testing.expectEqual(false, p.isClosed());
    }

    {
        // Closed at the end (not in the middle)
        var p = try initCapacity(alloc, 0);
        defer p.deinit(alloc);
        try p.moveTo(alloc, 1, 1);
        try p.lineTo(alloc, 2, 2);
        try p.moveTo(alloc, 3, 3);
        try p.lineTo(alloc, 4, 4);
        try p.lineTo(alloc, 5, 5);
        try p.close(alloc);
        try testing.expectEqual(false, p.isClosed());
    }

    {
        // Empty node set
        var p = try initCapacity(alloc, 0);
        defer p.deinit(alloc);
        try testing.expectEqual(false, p.isClosed());
    }
}

test "relMoveTo" {
    const alloc = testing.allocator;
    {
        // Normal
        var p = try initCapacity(alloc, 0);
        defer p.deinit(alloc);
        try p.moveTo(alloc, 1, 1);
        try p.relMoveTo(alloc, 1, 1);
        try testing.expectEqual(PathNode{ .move_to = .{ .point = .{ .x = 1, .y = 1 } } }, p.nodes.items[0]);
        try testing.expectEqual(PathNode{ .move_to = .{ .point = .{ .x = 2, .y = 2 } } }, p.nodes.items[1]);
        try testing.expectEqual(Point{ .x = 2, .y = 2 }, p.initial_point);
        try testing.expectEqual(Point{ .x = 2, .y = 2 }, p.current_point);
    }

    {
        // Reverse
        var p = try initCapacity(alloc, 0);
        defer p.deinit(alloc);
        try p.moveTo(alloc, 1, 1);
        try p.relMoveTo(alloc, -10, -10);
        try testing.expectEqual(PathNode{ .move_to = .{ .point = .{ .x = 1, .y = 1 } } }, p.nodes.items[0]);
        try testing.expectEqual(PathNode{ .move_to = .{ .point = .{ .x = -9, .y = -9 } } }, p.nodes.items[1]);
        try testing.expectEqual(Point{ .x = -9, .y = -9 }, p.initial_point);
        try testing.expectEqual(Point{ .x = -9, .y = -9 }, p.current_point);
    }

    {
        // No current point
        var p = try initCapacity(alloc, 0);
        defer p.deinit(alloc);
        try testing.expectEqual(error.NoCurrentPoint, p.relMoveTo(alloc, 1, 1));
    }
}

test "relLineTo" {
    const alloc = testing.allocator;
    {
        // Normal
        var p = try initCapacity(alloc, 0);
        defer p.deinit(alloc);
        try p.moveTo(alloc, 1, 1);
        try p.relLineTo(alloc, 1, 1);
        try testing.expectEqual(PathNode{ .move_to = .{ .point = .{ .x = 1, .y = 1 } } }, p.nodes.items[0]);
        try testing.expectEqual(PathNode{ .line_to = .{ .point = .{ .x = 2, .y = 2 } } }, p.nodes.items[1]);
        try testing.expectEqual(Point{ .x = 1, .y = 1 }, p.initial_point);
        try testing.expectEqual(Point{ .x = 2, .y = 2 }, p.current_point);
    }

    {
        // Reverse
        var p = try initCapacity(alloc, 0);
        defer p.deinit(alloc);
        try p.moveTo(alloc, 1, 1);
        try p.relLineTo(alloc, -10, -10);
        try testing.expectEqual(PathNode{ .move_to = .{ .point = .{ .x = 1, .y = 1 } } }, p.nodes.items[0]);
        try testing.expectEqual(PathNode{ .line_to = .{ .point = .{ .x = -9, .y = -9 } } }, p.nodes.items[1]);
        try testing.expectEqual(Point{ .x = 1, .y = 1 }, p.initial_point);
        try testing.expectEqual(Point{ .x = -9, .y = -9 }, p.current_point);
    }

    {
        // No current point
        var p = try initCapacity(alloc, 0);
        defer p.deinit(alloc);
        try testing.expectEqual(error.NoCurrentPoint, p.relLineTo(alloc, 1, 1));
    }
}

test "relCurveTo" {
    const alloc = testing.allocator;
    {
        // Normal
        var p = try initCapacity(alloc, 0);
        defer p.deinit(alloc);
        try p.moveTo(alloc, 1, 1);
        try p.relCurveTo(alloc, 1, 1, 2, 2, 3, 3);
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
        var p = try initCapacity(alloc, 0);
        defer p.deinit(alloc);
        try p.moveTo(alloc, 1, 1);
        try p.relCurveTo(alloc, -10, -10, -11, -11, -12, -12);
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
        var p = try initCapacity(alloc, 0);
        defer p.deinit(alloc);
        try testing.expectEqual(error.NoCurrentPoint, p.relCurveTo(alloc, 1, 1, 2, 2, 3, 3));
    }
}

test "relative helpers with transformations" {
    const alloc = testing.allocator;
    var p = try initCapacity(alloc, 0);
    defer p.deinit(alloc);

    p.transformation = p.transformation.translate(100, 200);
    try p.moveTo(alloc, 0, 0);
    try testing.expectEqual(PathNode{
        .move_to = .{
            .point = .{ .x = 100, .y = 200 },
        },
    }, p.nodes.items[0]);
    try p.relMoveTo(alloc, -10, -20);
    try testing.expectEqual(PathNode{
        .move_to = .{
            .point = .{ .x = 90, .y = 180 },
        },
    }, p.nodes.items[1]);

    p.reset();
    try p.moveTo(alloc, 0, 0);
    try p.relLineTo(alloc, -10, -20);
    try testing.expectEqual(PathNode{
        .line_to = .{
            .point = .{ .x = 90, .y = 180 },
        },
    }, p.nodes.items[1]);

    p.reset();
    try p.moveTo(alloc, 0, 0);
    try p.relCurveTo(alloc, -10, -20, 30, 40, -50, -60);
    try testing.expectEqual(PathNode{
        .curve_to = .{
            .p1 = .{ .x = 90, .y = 180 },
            .p2 = .{ .x = 130, .y = 240 },
            .p3 = .{ .x = 50, .y = 140 },
        },
    }, p.nodes.items[1]);
}
