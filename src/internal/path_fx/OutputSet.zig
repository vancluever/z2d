// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024-2026 Chris Marchesi

//! Output set for path effects. Much simpler than input sets, basically just
//! holds a set of points for the contour and the helpers to record them with a
//! path builder.
const OutputSet = @This();

const std = @import("std");

const nodepkg = @import("../path_nodes.zig");

const Path = @import("../../Path.zig");
const Point = @import("../Point.zig");

contours: std.ArrayList(Contour) = .empty,

pub const empty: OutputSet = .{};

pub fn deinit(self: *OutputSet, alloc: std.mem.Allocator) void {
    for (self.contours.items) |*contour| {
        contour.deinit(alloc);
    }

    self.contours.deinit(alloc);
    self.* = undefined;
}

pub const ToNodesError = Path.Error || std.mem.Allocator.Error;

/// Caller owns the memory.
pub fn toNodes(self: *OutputSet, alloc: std.mem.Allocator) ToNodesError![]nodepkg.PathNode {
    var result: Path = .empty;
    defer result.deinit(alloc);
    for (self.contours.items) |contour| {
        try contour.recordPath(alloc, &result);
    }

    return try result.nodes.toOwnedSlice(alloc);
}

pub const Contour = struct {
    points: std.ArrayList(Point) = .empty,
    closed: bool = false,

    pub const empty: Contour = .{};

    pub fn deinit(self: *Contour, alloc: std.mem.Allocator) void {
        self.points.deinit(alloc);
        self.* = undefined;
    }

    /// Asserts that the contour is not closed.
    pub fn plot(self: *Contour, alloc: std.mem.Allocator, point: Point) std.mem.Allocator.Error!void {
        std.debug.assert(!self.closed);
        try self.points.append(alloc, point);
    }

    /// Asserts that there is at least three segments in the contour, and that the
    /// contour is not closed.
    pub fn close(self: *Contour) void {
        std.debug.assert(self.points.items.len >= 3);
        std.debug.assert(!self.closed);
        self.closed = true;
    }

    fn recordPath(self: *const Contour, alloc: std.mem.Allocator, path: *Path) std.mem.Allocator.Error!void {
        if (self.points.items.len <= 1) {
            return;
        }

        try path.moveTo(alloc, self.points.items[0].x, self.points.items[0].y);
        for (self.points.items[1..]) |point| {
            try path.lineTo(alloc, point.x, point.y);
        }

        if (self.closed) {
            try path.close(alloc);
        }
    }
};

test "toNodes e2e" {
    const alloc = std.testing.allocator;
    {
        // Open
        var output_set: OutputSet = .empty;
        defer output_set.deinit(alloc);
        {
            var contour: Contour = .empty;
            errdefer contour.deinit(alloc);
            try contour.plot(alloc, .{ .x = 18, .y = 61 });
            try contour.plot(alloc, .{ .x = 25, .y = 61 });
            try contour.plot(alloc, .{ .x = 25, .y = 68 });
            try contour.plot(alloc, .{ .x = 18, .y = 68 });
            contour.close();
            try output_set.contours.append(alloc, contour);
        }

        {
            var contour: Contour = .empty;
            errdefer contour.deinit(alloc);
            try contour.plot(alloc, .{ .x = 34, .y = 58 });
            try contour.plot(alloc, .{ .x = 37, .y = 64 });
            try contour.plot(alloc, .{ .x = 34, .y = 70 });
            try output_set.contours.append(alloc, contour);
        }

        const expected = [_]nodepkg.PathNode{
            .{ .move_to = .{ .point = .{ .x = 18, .y = 61 } } },
            .{ .line_to = .{ .point = .{ .x = 25, .y = 61 } } },
            .{ .line_to = .{ .point = .{ .x = 25, .y = 68 } } },
            .{ .line_to = .{ .point = .{ .x = 18, .y = 68 } } },
            .{ .close_path = .{} },
            .{ .move_to = .{ .point = .{ .x = 18, .y = 61 } } },
            .{ .move_to = .{ .point = .{ .x = 34, .y = 58 } } },
            .{ .line_to = .{ .point = .{ .x = 37, .y = 64 } } },
            .{ .line_to = .{ .point = .{ .x = 34, .y = 70 } } },
        };

        const got = try output_set.toNodes(alloc);
        defer alloc.free(got);
        try std.testing.expectEqualDeep(&expected, got);
    }
}

test "Contour e2e" {
    const alloc = std.testing.allocator;
    {
        // Open
        var contour: Contour = .empty;
        defer contour.deinit(alloc);
        try contour.plot(alloc, .{ .x = 18, .y = 61 });
        try contour.plot(alloc, .{ .x = 25, .y = 61 });
        try contour.plot(alloc, .{ .x = 25, .y = 68 });
        try contour.plot(alloc, .{ .x = 18, .y = 68 });
        contour.close();

        var got: Path = .empty;
        defer got.deinit(alloc);

        const expected = [_]nodepkg.PathNode{
            .{ .move_to = .{ .point = .{ .x = 18, .y = 61 } } },
            .{ .line_to = .{ .point = .{ .x = 25, .y = 61 } } },
            .{ .line_to = .{ .point = .{ .x = 25, .y = 68 } } },
            .{ .line_to = .{ .point = .{ .x = 18, .y = 68 } } },
            .{ .close_path = .{} },
            .{ .move_to = .{ .point = .{ .x = 18, .y = 61 } } },
        };

        try contour.recordPath(alloc, &got);
        try std.testing.expectEqualDeep(&expected, got.nodes.items);
    }

    {
        // Closed
        var contour: Contour = .empty;
        defer contour.deinit(alloc);
        try contour.plot(alloc, .{ .x = 18, .y = 61 });
        try contour.plot(alloc, .{ .x = 25, .y = 61 });
        try contour.plot(alloc, .{ .x = 25, .y = 68 });
        try contour.plot(alloc, .{ .x = 18, .y = 68 });

        var got: Path = .empty;
        defer got.deinit(alloc);

        const expected = [_]nodepkg.PathNode{
            .{ .move_to = .{ .point = .{ .x = 18, .y = 61 } } },
            .{ .line_to = .{ .point = .{ .x = 25, .y = 61 } } },
            .{ .line_to = .{ .point = .{ .x = 25, .y = 68 } } },
            .{ .line_to = .{ .point = .{ .x = 18, .y = 68 } } },
        };

        try contour.recordPath(alloc, &got);
        try std.testing.expectEqualDeep(&expected, got.nodes.items);
    }

    {
        // No points
        var contour: Contour = .empty;
        defer contour.deinit(alloc);
        var got: Path = .empty;
        defer got.deinit(alloc);
        try contour.recordPath(alloc, &got);
        try std.testing.expectEqual(0, got.nodes.items.len);
    }

    {
        // One point
        var contour: Contour = .empty;
        defer contour.deinit(alloc);
        var got: Path = .empty;
        defer got.deinit(alloc);
        try contour.plot(alloc, .{ .x = 18, .y = 61 });
        try contour.recordPath(alloc, &got);
        try std.testing.expectEqual(0, got.nodes.items.len);
    }
}
