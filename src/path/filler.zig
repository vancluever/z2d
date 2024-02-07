const std = @import("std");
const debug = @import("std").debug;
const mem = @import("std").mem;

const nodepkg = @import("nodes.zig");
const patternpkg = @import("../pattern.zig");
const polypkg = @import("polygon.zig");
const surfacepkg = @import("../surface.zig");
const spline = @import("spline_transformer.zig");
const units = @import("../units.zig");

/// Runs a fill operation (even-odd) on this current path and any subpaths.
pub fn fill(
    alloc: mem.Allocator,
    nodes: *std.ArrayList(nodepkg.PathNode),
    surface: surfacepkg.Surface,
    pattern: patternpkg.Pattern,
) !void {
    debug.assert(nodes.items.len != 0); // Should not be called with zero nodes
    debug.assert(nodes.getLast() == .close_path); // Path should be pre-closed by higher-level callers

    var polygon = try plot(alloc, nodes);
    defer polygon.deinit();

    // Now, for every y in our surface, get our edges and set our fill pixels.
    const poly_start_y: usize = @intFromFloat(polygon.start.y);
    const poly_end_y: usize = @intFromFloat(polygon.end.y);
    for (poly_start_y..poly_end_y + 1) |y| {
        // Get our edges for this y
        var edge_list = try polygon.edgesForY(@floatFromInt(y));
        defer edge_list.deinit();

        // Currently even-odd fill only. TODO: add non-zero.
        var start_idx: usize = 0;
        while (start_idx + 1 < edge_list.items.len) {
            const start_x = @min(
                surface.getWidth(),
                edge_list.items[start_idx],
            );
            const end_x = @min(
                surface.getWidth(),
                edge_list.items[start_idx + 1],
            );

            for (start_x..end_x + 1) |x| {
                const pixel = try pattern.getPixel(@intCast(x), @intCast(y));
                try surface.putPixel(@intCast(x), @intCast(y), pixel);
            }

            start_idx += 2;
        }
    }
}

/// parses the node list and plots the points therein, and returns a polygon
/// suitable for filling.
///
/// The caller owns the polygon and needs to call deinit on it.
fn plot(alloc: mem.Allocator, nodes: *std.ArrayList(nodepkg.PathNode)) !polypkg.Polygon {
    var polygon = polypkg.Polygon.init(alloc);
    errdefer polygon.deinit();

    var initial_point: ?units.Point = null;
    var current_point: ?units.Point = null;

    for (nodes.items) |node| {
        switch (node) {
            .move_to => |n| {
                try polygon.plot(n.point);
                initial_point = n.point;
                current_point = n.point;
            },
            .line_to => |n| {
                debug.assert(initial_point != null);
                debug.assert(current_point != null);

                try polygon.plot(n.point);
                current_point = n.point;
            },
            .curve_to => |n| {
                debug.assert(initial_point != null);
                debug.assert(current_point != null);

                var transformed_nodes = try spline.transform(
                    alloc,
                    current_point.?,
                    n.p1,
                    n.p2,
                    n.p3,
                    0.1, // TODO: make tolerance configurable
                );
                defer transformed_nodes.deinit();

                // We just iterate through the node list here and plot directly.
                for (transformed_nodes.items) |tn| {
                    switch (tn) {
                        .line_to => |tnn| try polygon.plot(tnn.point),
                        else => unreachable, // spline transformer does not return anything else
                    }
                }
            },
            .close_path => {
                debug.assert(initial_point != null);
                debug.assert(current_point != null);

                // No-op if our initial and current points are equal
                if (current_point.?.equal(initial_point.?)) break;

                // Do an append on the edges only for now (not corners). We will
                // simplify this when we remove corners, for now this keeps the
                // starting corner from being duplicated.
                //
                // TODO: we're directly accessing the polygon here, which is a
                // bit of an anti-pattern... this will be removed after the
                // fill/stroke model stabilizes.
                try polygon.edges.append(
                    polypkg.PolygonEdge.fromPoints(current_point.?, initial_point.?),
                );

                // Set the current point to the initial point.
                current_point = initial_point;
            },
        }
    }

    return polygon;
}
