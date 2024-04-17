// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024 Chris Marchesi

const Point = @import("Point.zig");

/// A tagged union of all path node types.
pub const PathNodeTag = enum {
    move_to,
    line_to,
    curve_to,
    close_path,
};

pub const PathNode = union(PathNodeTag) {
    move_to: PathMoveTo,
    line_to: PathLineTo,
    curve_to: PathCurveTo,
    close_path: PathClose,
};

/// Represents a moveto path node. This starts a new subpath and moves the
/// current point to (x, y).
pub const PathMoveTo = struct {
    point: Point,
};

/// Represents a lineto path node. This draws a line to (x, y) and sets it as
/// its current point.
pub const PathLineTo = struct {
    point: Point,
};

/// Represents a curveto path node. This draws a cubic bezier with the three
/// supplied control points from the current point. The new current point is
/// set to p3.
pub const PathCurveTo = struct {
    p1: Point,
    p2: Point,
    p3: Point,
};

/// Represents a closepath node.
pub const PathClose = struct {};
