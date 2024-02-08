const std = @import("std");
const debug = @import("std").debug;
const math = @import("std").math;
const mem = @import("std").mem;

const units = @import("../units.zig");
const nodepkg = @import("nodes.zig");

/// Transforms a set of PathNode into a new PathNode set that represents a
/// fillable path for a line stroke operation. The path is generated with the
/// supplied thickness.
///
/// The returned node list is owned by the caller and deinit should be
/// called on it.
pub fn transform(
    alloc: mem.Allocator,
    nodes: *std.ArrayList(nodepkg.PathNode),
    thickness: f64,
) !std.ArrayList(nodepkg.PathNode) {
    var result = std.ArrayList(nodepkg.PathNode).init(alloc);
    errdefer result.deinit();

    var it: StrokeNodeIterator = .{
        .alloc = alloc,
        .thickness = thickness,
        .items = nodes,
    };

    while (try it.next()) |x| {
        defer x.deinit();
        try result.appendSlice(x.items);
    }

    return result;
}

/// An iterator that advances a list of PathNodes by each fillable line.
const StrokeNodeIterator = struct {
    alloc: mem.Allocator,
    thickness: f64,
    items: *const std.ArrayList(nodepkg.PathNode),
    index: usize = 0,

    pub fn next(it: *StrokeNodeIterator) !?std.ArrayList(nodepkg.PathNode) {
        debug.assert(it.index <= it.items.items.len);
        if (it.index >= it.items.items.len) return null;

        // Our line joins.
        //
        // TODO: Maybe group these for symmetry with things like len and other
        // operations that make the assumption (correctly) that both of these
        // will always be of equal length.
        var outer_joins = std.ArrayList(units.Point).init(it.alloc);
        var inner_joins = std.ArrayList(units.Point).init(it.alloc);
        defer outer_joins.deinit();
        defer inner_joins.deinit();

        // Our point state for the transformer. We need at least 3 points to
        // calculate a join, so we keep track of 2 points here (last point, current
        // point) and combine that with the point being processed. The initial
        // point stores the point of our last move_to.
        var initial_point_: ?units.Point = null;
        var current_point_: ?units.Point = null;
        var last_point_: ?units.Point = null;

        while (it.index < it.items.items.len) : (it.index += 1) {
            switch (it.items.items[it.index]) {
                .move_to => |node| {
                    // move_to with initial point means we're at the end of the
                    // current line
                    if (initial_point_ != null) break;

                    initial_point_ = node.point;
                    current_point_ = node.point;
                },
                .curve_to => {
                    if (initial_point_ != null) {
                        // TODO: handle curve_to
                    } else unreachable; // curve_to should never be called internally without move_to
                },
                .line_to => |node| {
                    if (initial_point_ != null) {
                        if (last_point_ != null) {
                            // TODO: Add join here
                        }
                        last_point_ = current_point_;
                        current_point_ = node.point;
                    } else unreachable; // line_to should never be called internally without move_to
                },
                .close_path => {
                    if (initial_point_ != null) {
                        // TODO: handle close_path
                    } else unreachable; // close_path should never be called internally without move_to
                },
            }
        }

        if (initial_point_) |initial_point| {
            if (current_point_) |current_point| {
                if (initial_point.equal(current_point) and outer_joins.items.len == 0) {
                    // This means that the line was never effectively moved to
                    // another point, so we should not draw anything.
                    return std.ArrayList(nodepkg.PathNode).init(it.alloc);
                }

                // Initialize the result to the size of our joins, plus 5 nodes for:
                //
                // * Initial move_to (outer cap point)
                // * End cap line_to nodes
                // * Start inner cap point
                // * Final close_path node
                //
                // This will possibly change when we add more cap modes (round
                // caps particularly may keep us from being able to
                // pre-determine capacity).
                var result = try std.ArrayList(nodepkg.PathNode).initCapacity(
                    it.alloc,
                    outer_joins.items.len + inner_joins.items.len + 5,
                );
                errdefer result.deinit();

                // TODO: handle join points
                const cap_points = capButt(initial_point, current_point, it.thickness);
                try result.append(.{ .move_to = .{ .point = cap_points[0] } });
                try result.append(.{ .line_to = .{ .point = cap_points[2] } });
                try result.append(.{ .line_to = .{ .point = cap_points[3] } });
                try result.append(.{ .line_to = .{ .point = cap_points[1] } });
                try result.append(.{ .close_path = .{} });

                // Done
                return result;
            } else unreachable; // move_to sets both initial and current points
        }

        // Invalid if we've hit this point (state machine never allows initial
        // point to not be set)
        unreachable;
    }
};

/// Given two points and a thickness, return points for a "butt cap" (a line
/// cap that ends exactly at the end of the line) for both points (order
/// (outer, inner), (outer, inner)).
fn capButt(p0: units.Point, p1: units.Point, thickness: f64) [4]units.Point {
    const dy = p1.y - p0.y;
    const dx = p1.x - p0.x;

    // Special cases
    if (dy == 0) {
        // Horizontal line
        return .{
            .{ .x = p0.x, .y = p0.y - thickness / 2 },
            .{ .x = p0.x, .y = p0.y + thickness / 2 },
            .{ .x = p1.x, .y = p1.y - thickness / 2 },
            .{ .x = p1.x, .y = p1.y + thickness / 2 },
        };
    }
    if (dx == 0) {
        // Vertical line
        return .{
            .{ .x = p0.x - thickness / 2, .y = p0.y },
            .{ .x = p0.x + thickness / 2, .y = p0.y },
            .{ .x = p1.x - thickness / 2, .y = p1.y },
            .{ .x = p1.x + thickness / 2, .y = p1.y },
        };
    }

    // The slopes of our end points are actually technically opposite of the
    // actual slope (so "normal" is actually m = dx/dy). This, however, depends
    // on the quadrant of the direction of the line.
    if (dx >= 0 and dy < 0 or dx < 0 and dy >= 0) {
        // We're in a flipped quadrant where either one of x or y is
        // decreasing, and the other is increasing, so our slope (m) is
        // calculated dy/dx.
        const theta = math.atan(@abs(dy) / @abs(dx));
        const offset_x = thickness / 2 * @cos(theta);
        const offset_y = thickness / 2 * @sin(theta);
        return .{
            .{ .x = p0.x - offset_x, .y = p0.y - offset_y },
            .{ .x = p0.x + offset_x, .y = p0.y + offset_y },
            .{ .x = p1.x - offset_x, .y = p1.y - offset_y },
            .{ .x = p1.x + offset_x, .y = p1.y + offset_y },
        };
    }

    // This is the normal case where both deltas are increasing (or
    // decreasing).
    const theta = math.atan(@abs(dx) / @abs(dy));
    const offset_x = thickness / 2 * @cos(theta);
    const offset_y = thickness / 2 * @sin(theta);
    return .{
        .{ .x = p0.x + offset_x, .y = p0.y - offset_y },
        .{ .x = p0.x - offset_x, .y = p0.y + offset_y },
        .{ .x = p1.x + offset_x, .y = p1.y - offset_y },
        .{ .x = p1.x - offset_x, .y = p1.y + offset_y },
    };
}
