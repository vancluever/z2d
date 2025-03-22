// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024-2025 Chris Marchesi

const testing = @import("std").testing;

const Path = @import("Path.zig");
const PathNode = @import("internal/path_nodes.zig").PathNode;

/// Represents a wrapper over the fully unmanaged representation of a `Path`;
/// nodes are stored in a static buffer of the specified `len`, and
/// initialization of the wrapped path is done using `Path.initBuffer`.
///
/// Make sure to call `init` after declaring a `StaticPath` to initialize.
///
/// All top-level methods of `StaticPath` are infallible and are idiomatically
/// wrapped to their appropriate counterparts in `Path`. Note that methods that
/// do usually fail due to non-memory reasons (e.g., no current point, etc.)
/// are safety-checked undefined behavior when they would normally return an
/// error.
///
/// Not all `Path` methods are wrapped, nor are the fields exposed through
/// setters. If you require a feature of `Path` that is not wrapped or exposed
/// (such as manipulation of the transformation matrix), you can access the
/// instance directly through the `wrapped_path` field. Standard caveats apply;
/// note that `Path.arc` and `Path.arcNegative`, for example, currently have no
/// externally managed method equivalent, and as such, can't be used with
/// `StaticPath`.
pub fn StaticPath(comptime len: usize) type {
    return struct {
        nodes: [len]PathNode = undefined,
        wrapped_path: Path = undefined,

        /// Initialize the wrapped path with the node buffer.
        pub fn init(self: *StaticPath(len)) void {
            self.wrapped_path = Path.initBuffer(&self.nodes);
        }

        /// Rests the path set, clearing all nodes and state.
        pub fn reset(self: *StaticPath(len)) void {
            self.wrapped_path.reset();
        }

        /// Starts a new path, and moves the current point to it.
        pub fn moveTo(self: *StaticPath(len), x: f64, y: f64) void {
            self.wrapped_path.moveToAssumeCapacity(x, y);
        }

        /// Begins a new sub-path relative to the current point. Calling this
        /// without a current point triggers safety-checked undefined behavior.
        pub fn relMoveTo(self: *StaticPath(len), x: f64, y: f64) void {
            self.wrapped_path.relMoveToAssumeCapacity(x, y) catch unreachable;
        }

        /// Draws a line from the current point to the specified point and sets
        /// it as the current point. Acts as a `moveTo` instead if there is no
        /// current point.
        pub fn lineTo(self: *StaticPath(len), x: f64, y: f64) void {
            self.wrapped_path.lineToAssumeCapacity(x, y);
        }

        /// Draws a line relative to the current point. Calling this without a
        /// current point triggers safety-checked undefined behavior.
        pub fn relLineTo(self: *StaticPath(len), x: f64, y: f64) void {
            self.wrapped_path.relLineToAssumeCapacity(x, y) catch unreachable;
        }

        /// Draws a cubic bezier with the three supplied control points from
        /// the current point. The new current point is set to (`x3`, `y3`).
        /// Calling this without a current point triggers safety-checked
        /// undefined behavior.
        pub fn curveTo(
            self: *StaticPath(len),
            x1: f64,
            y1: f64,
            x2: f64,
            y2: f64,
            x3: f64,
            y3: f64,
        ) void {
            self.wrapped_path.curveToAssumeCapacity(x1, y1, x2, y2, x3, y3) catch unreachable;
        }

        /// Draws a cubic bezier relative to the current point. Calling this
        /// without a current point triggers safety-checked undefined behavior.
        pub fn relCurveTo(
            self: *StaticPath(len),
            x1: f64,
            y1: f64,
            x2: f64,
            y2: f64,
            x3: f64,
            y3: f64,
        ) void {
            self.wrapped_path.relCurveToAssumeCapacity(x1, y1, x2, y2, x3, y3) catch unreachable;
        }

        /// Closes the path by drawing a line from the current point by the
        /// starting point. No effect if there is no current point.
        ///
        /// Note that path closes require two points, one for the `close_path`
        /// entry, and one for the implicit `move_to` entry; ensure your
        /// `StaticPath` has enough space for both.
        pub fn close(self: *StaticPath(len)) void {
            self.wrapped_path.closeAssumeCapacity();
        }
    };
}

test "StaticPath" {
    {
        // Basic
        var path: StaticPath(5) = .{};
        path.init();
        path.moveTo(10, 10);
        path.lineTo(30, 10);
        path.lineTo(20, 30);
        path.close();
        try testing.expectEqual([_]PathNode{
            .{ .move_to = .{ .point = .{ .x = 10, .y = 10 } } },
            .{ .line_to = .{ .point = .{ .x = 30, .y = 10 } } },
            .{ .line_to = .{ .point = .{ .x = 20, .y = 30 } } },
            .{ .close_path = .{} },
            .{ .move_to = .{ .point = .{ .x = 10, .y = 10 } } },
        }, path.nodes);
    }

    {
        // Relative line helpers
        var path: StaticPath(5) = .{};
        path.init();
        path.moveTo(10, 10);
        path.relLineTo(20, 0);
        path.relLineTo(-10, 20);
        path.close();
        try testing.expectEqual([_]PathNode{
            .{ .move_to = .{ .point = .{ .x = 10, .y = 10 } } },
            .{ .line_to = .{ .point = .{ .x = 30, .y = 10 } } },
            .{ .line_to = .{ .point = .{ .x = 20, .y = 30 } } },
            .{ .close_path = .{} },
            .{ .move_to = .{ .point = .{ .x = 10, .y = 10 } } },
        }, path.nodes);
    }

    {
        // curveTo
        var path: StaticPath(2) = .{};
        path.init();
        path.moveTo(10, 10);
        path.curveTo(30, 10, 30, 30, 10, 30);
        try testing.expectEqual([_]PathNode{
            .{ .move_to = .{ .point = .{ .x = 10, .y = 10 } } },
            .{ .curve_to = .{
                .p1 = .{ .x = 30, .y = 10 },
                .p2 = .{ .x = 30, .y = 30 },
                .p3 = .{ .x = 10, .y = 30 },
            } },
        }, path.nodes);
    }

    {
        // relCurveTo
        var path: StaticPath(2) = .{};
        path.init();
        path.moveTo(10, 10);
        path.relCurveTo(20, 0, 20, 20, 0, 20);
        try testing.expectEqual([_]PathNode{
            .{ .move_to = .{ .point = .{ .x = 10, .y = 10 } } },
            .{ .curve_to = .{
                .p1 = .{ .x = 30, .y = 10 },
                .p2 = .{ .x = 30, .y = 30 },
                .p3 = .{ .x = 10, .y = 30 },
            } },
        }, path.nodes);
    }

    {
        // relMoveTo
        var path: StaticPath(3) = .{};
        path.init();
        path.moveTo(10, 10);
        path.lineTo(20, 20);
        path.relMoveTo(10, 10);
        try testing.expectEqual([_]PathNode{
            .{ .move_to = .{ .point = .{ .x = 10, .y = 10 } } },
            .{ .line_to = .{ .point = .{ .x = 20, .y = 20 } } },
            .{ .move_to = .{ .point = .{ .x = 30, .y = 30 } } },
        }, path.nodes);
    }

    {
        // reset
        var path: StaticPath(5) = .{};
        path.init();
        path.moveTo(10, 10);
        path.lineTo(30, 10);
        path.lineTo(20, 30);
        path.close();
        try testing.expectEqual([_]PathNode{
            .{ .move_to = .{ .point = .{ .x = 10, .y = 10 } } },
            .{ .line_to = .{ .point = .{ .x = 30, .y = 10 } } },
            .{ .line_to = .{ .point = .{ .x = 20, .y = 30 } } },
            .{ .close_path = .{} },
            .{ .move_to = .{ .point = .{ .x = 10, .y = 10 } } },
        }, path.nodes);
        path.reset();
        path.moveTo(100, 100);
        path.lineTo(300, 100);
        path.lineTo(200, 300);
        path.close();
        try testing.expectEqual([_]PathNode{
            .{ .move_to = .{ .point = .{ .x = 100, .y = 100 } } },
            .{ .line_to = .{ .point = .{ .x = 300, .y = 100 } } },
            .{ .line_to = .{ .point = .{ .x = 200, .y = 300 } } },
            .{ .close_path = .{} },
            .{ .move_to = .{ .point = .{ .x = 100, .y = 100 } } },
        }, path.nodes);
    }
}
