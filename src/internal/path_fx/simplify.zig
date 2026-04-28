// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024-2026 Chris Marchesi

//! Polygon simplification.
//!
//! This effect simplifies a path so that all polygons returned are *simple*
//! polygons, meaning that they do not self-intersect.
//!
//! Currently, our algorithm also has the limitation of only returning the
//! outer polygon of a path that has possible inner polygons. Consider the
//! classic 5-point self-intersecting star: we return only the outer path, not
//! the inner pentagon or the 5 composite triangles that border said pentagon.
//!
//! With that said, when intersections are self-sealing - that is, the
//! intersection splits a polygon in two by itself, both polygons will be
//! returned.
//!
//! Note that this effect also ignores unclosed paths and returns them unmodified.

const std = @import("std");

const nodepkg = @import("../path_nodes.zig");
const shared = @import("shared.zig");

const InputSet = @import("InputSet.zig");
const OutputSet = @import("OutputSet.zig");
const Point = @import("../Point.zig");

pub const Error = InputSet.FromNodesError || OutputSet.ToNodesError || std.mem.Allocator.Error;

/// Caller owns the memory.
pub fn run(
    alloc: std.mem.Allocator,
    in: []const nodepkg.PathNode,
    tolerance: f64,
) Error![]nodepkg.PathNode {
    var input_set = try InputSet.fromNodes(alloc, in, tolerance);
    defer input_set.deinit(alloc);
    var output_set: OutputSet = .empty;
    defer output_set.deinit(alloc);
    for (input_set.contours.items) |*contour| {
        if (contour.closed) {
            contour.alignSegments();
            try contour.computeIntersections(alloc);
            try runContour(alloc, &output_set, contour, .initial);
        } else {
            try shared.noopContour(alloc, &output_set, contour);
        }
    }

    return try output_set.toNodes(alloc);
}

/// Asserts that the input contour is closed and has at least 3 nodes.
fn runContour(
    alloc: std.mem.Allocator,
    out: *OutputSet,
    in: *const InputSet.Contour,
    state: State,
) std.mem.Allocator.Error!void {
    std.debug.assert(in.closed);
    std.debug.assert(in.segments.items.len >= 3);

    var result: OutputSet.Contour = .empty;
    errdefer result.deinit(alloc);
    var idx: usize, var initial_point: ?Point, const clockwise: bool = switch (state) {
        .initial => .{ 0, null, in.segments.items[0].orientation == .cw },
        .intersection => |isect| .{ isect.segment_idx, isect.point, isect.clockwise },
    };
    while (idx < in.segments.items.len) : (idx += 1) {
        const seg = &in.segments.items[idx];
        if (initial_point) |pt| {
            try result.plot(alloc, pt);
            initial_point = null;
        } else {
            try result.plot(alloc, seg.p0);
        }

        if (seg.unshiftIntersection()) |isect| {
            if (state == .intersection and state.intersection.intersection_id == isect.id) {
                break;
            }

            if (clockwise == (isect.orientation == .cw)) {
                try runContour(alloc, out, in, .{ .intersection = .{
                    .segment_idx = idx,
                    .intersection_id = isect.id,
                    .point = isect.point,
                    .clockwise = !(isect.orientation == .cw),
                } });
            }

            try result.plot(alloc, isect.point);
            idx = isect.out_idx;
        }
    }

    result.close();
    try out.contours.append(alloc, result);
}

const State = union(enum) {
    initial: void,
    intersection: struct {
        segment_idx: usize,
        intersection_id: usize,
        point: Point,
        clockwise: bool,
    },
};

test "simplify e2e" {
    const alloc = std.testing.allocator;
    const in = [_]nodepkg.PathNode{
        // Star
        .{ .move_to = .{ .point = .{ .x = 25, .y = 5 } } },
        .{ .line_to = .{ .point = .{ .x = 32, .y = 25 } } },
        .{ .line_to = .{ .point = .{ .x = 15, .y = 13 } } },
        .{ .line_to = .{ .point = .{ .x = 35, .y = 13 } } },
        .{ .line_to = .{ .point = .{ .x = 18, .y = 25 } } },
        .{ .close_path = .{} },
        .{ .move_to = .{ .point = .{ .x = 25, .y = 5 } } },
        // Self-sealing
        .{ .move_to = .{ .point = .{ .x = 23, .y = 39 } } },
        .{ .line_to = .{ .point = .{ .x = 27, .y = 50 } } },
        .{ .line_to = .{ .point = .{ .x = 21, .y = 50 } } },
        .{ .line_to = .{ .point = .{ .x = 28, .y = 43 } } },
        .{ .line_to = .{ .point = .{ .x = 20, .y = 43 } } },
        .{ .close_path = .{} },
        .{ .move_to = .{ .point = .{ .x = 23, .y = 39 } } },
        // Open (should no-op)
        .{ .move_to = .{ .point = .{ .x = 34, .y = 58 } } },
        .{ .line_to = .{ .point = .{ .x = 37, .y = 64 } } },
        .{ .line_to = .{ .point = .{ .x = 34, .y = 70 } } },
    };

    const expected = [_]nodepkg.PathNode{
        // Star
        .{ .move_to = .{ .point = .{ .x = 15, .y = 13 } } },
        .{ .line_to = .{ .point = .{ .x = 22.2, .y = 13 } } },
        .{ .line_to = .{ .point = .{ .x = 25, .y = 5 } } },
        .{ .line_to = .{ .point = .{ .x = 27.8, .y = 13 } } },
        .{ .line_to = .{ .point = .{ .x = 35, .y = 13 } } },
        .{ .line_to = .{ .point = .{ .x = 29.22641509433962, .y = 17.07547169811321 } } },
        .{ .line_to = .{ .point = .{ .x = 32, .y = 25 } } },
        .{ .line_to = .{ .point = .{ .x = 25, .y = 20.058823529411764 } } },
        .{ .line_to = .{ .point = .{ .x = 18, .y = 25 } } },
        .{ .line_to = .{ .point = .{ .x = 20.77358490566038, .y = 17.075471698113205 } } },
        .{ .close_path = .{} },
        .{ .move_to = .{ .point = .{ .x = 15, .y = 13 } } },
        // Self-sealing 1
        .{ .move_to = .{ .point = .{ .x = 25.4, .y = 45.6 } } },
        .{ .line_to = .{ .point = .{ .x = 27, .y = 50 } } },
        .{ .line_to = .{ .point = .{ .x = 21, .y = 50 } } },
        .{ .close_path = .{} },
        .{ .move_to = .{ .point = .{ .x = 25.4, .y = 45.6 } } },
        // Self-sealing 2
        .{ .move_to = .{ .point = .{ .x = 24.454545454545453, .y = 43 } } },
        .{ .line_to = .{ .point = .{ .x = 25.4, .y = 45.6 } } },
        .{ .line_to = .{ .point = .{ .x = 28, .y = 43 } } },
        .{ .close_path = .{} },
        .{ .move_to = .{ .point = .{ .x = 24.454545454545453, .y = 43 } } },
        // Self-sealing 2
        .{ .move_to = .{ .point = .{ .x = 20, .y = 43 } } },
        .{ .line_to = .{ .point = .{ .x = 23, .y = 39 } } },
        .{ .line_to = .{ .point = .{ .x = 24.454545454545453, .y = 43 } } },
        .{ .close_path = .{} },
        .{ .move_to = .{ .point = .{ .x = 20, .y = 43 } } },
        // Open (no-op'ed)
        .{ .move_to = .{ .point = .{ .x = 34, .y = 58 } } },
        .{ .line_to = .{ .point = .{ .x = 37, .y = 64 } } },
        .{ .line_to = .{ .point = .{ .x = 34, .y = 70 } } },
    };

    const out = try run(alloc, &in, 0.1);
    defer alloc.free(out);
    try std.testing.expectEqualDeep(&expected, out);
}
