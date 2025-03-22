// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024-2025 Chris Marchesi

const testing = @import("std").testing;

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

    /// Returns true if all subpaths in the set of PathNodes are currently closed.
    pub fn isClosedNodeSet(nodes: []const PathNode) bool {
        if (nodes.len == 0) return false;

        var closed = false;
        for (nodes, 0..) |node, i| {
            switch (node) {
                .move_to => if (!closed and i != 0) break,
                .close_path => closed = true,
                else => closed = false,
            }
        }

        return closed;
    }
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

test "isClosedNodeSet" {
    {
        // Basic (closed)
        const nodes = [_]PathNode{
            .{ .move_to = .{ .point = .{ .x = 1, .y = 1 } } },
            .{ .line_to = .{ .point = .{ .x = 2, .y = 2 } } },
            .{ .line_to = .{ .point = .{ .x = 3, .y = 3 } } },
            .{ .close_path = .{} },
            .{ .move_to = .{ .point = .{ .x = 1, .y = 1 } } },
        };
        try testing.expectEqual(true, PathNode.isClosedNodeSet(&nodes));
    }

    {
        // Multiple subpaths, all closed
        const nodes = [_]PathNode{
            .{ .move_to = .{ .point = .{ .x = 1, .y = 1 } } },
            .{ .line_to = .{ .point = .{ .x = 2, .y = 2 } } },
            .{ .line_to = .{ .point = .{ .x = 3, .y = 3 } } },
            .{ .close_path = .{} },
            .{ .move_to = .{ .point = .{ .x = 1, .y = 1 } } },
            .{ .move_to = .{ .point = .{ .x = 4, .y = 4 } } },
            .{ .line_to = .{ .point = .{ .x = 5, .y = 5 } } },
            .{ .line_to = .{ .point = .{ .x = 6, .y = 6 } } },
            .{ .close_path = .{} },
            .{ .move_to = .{ .point = .{ .x = 4, .y = 4 } } },
        };
        try testing.expectEqual(true, PathNode.isClosedNodeSet(&nodes));
    }

    {
        // Basic (not closed)
        const nodes = [_]PathNode{
            .{ .move_to = .{ .point = .{ .x = 1, .y = 1 } } },
            .{ .line_to = .{ .point = .{ .x = 2, .y = 2 } } },
            .{ .move_to = .{ .point = .{ .x = 3, .y = 3 } } },
            .{ .line_to = .{ .point = .{ .x = 4, .y = 4 } } },
            .{ .line_to = .{ .point = .{ .x = 5, .y = 5 } } },
        };
        try testing.expectEqual(false, PathNode.isClosedNodeSet(&nodes));
    }

    {
        // Closed in the middle
        const nodes = [_]PathNode{
            .{ .move_to = .{ .point = .{ .x = 1, .y = 1 } } },
            .{ .line_to = .{ .point = .{ .x = 2, .y = 2 } } },
            .{ .close_path = .{} },
            .{ .move_to = .{ .point = .{ .x = 1, .y = 1 } } },
            .{ .move_to = .{ .point = .{ .x = 3, .y = 3 } } },
            .{ .line_to = .{ .point = .{ .x = 4, .y = 4 } } },
            .{ .line_to = .{ .point = .{ .x = 5, .y = 5 } } },
        };
        try testing.expectEqual(false, PathNode.isClosedNodeSet(&nodes));
    }

    {
        // Closed at the end (not in the middle)
        const nodes = [_]PathNode{
            .{ .move_to = .{ .point = .{ .x = 1, .y = 1 } } },
            .{ .line_to = .{ .point = .{ .x = 2, .y = 2 } } },
            .{ .move_to = .{ .point = .{ .x = 3, .y = 3 } } },
            .{ .line_to = .{ .point = .{ .x = 4, .y = 4 } } },
            .{ .line_to = .{ .point = .{ .x = 5, .y = 5 } } },
            .{ .close_path = .{} },
            .{ .move_to = .{ .point = .{ .x = 3, .y = 3 } } },
        };
        try testing.expectEqual(false, PathNode.isClosedNodeSet(&nodes));
    }

    {
        // Empty node set
        try testing.expectEqual(false, PathNode.isClosedNodeSet(&.{}));
    }
}
