/// A Pen represents a circular area designed for specific stroking operations,
/// such as round joins and caps.
const Pen = @This();

const std = @import("std");
const math = @import("std").math;
const mem = @import("std").mem;

const Face = @import("face.zig");
const Point = @import("../units.zig").Point;
const Slope = @import("Slope.zig");

const PenVertex = struct {
    point: Point,
    slope_cw: Slope,
    slope_ccw: Slope,
};

alloc: mem.Allocator,

/// The vertices, centered around (0,0) and distributed on even angles
/// around the pen.
vertices: std.ArrayList(PenVertex),

/// Initializes a pen at radius thickness / 2, with point distribution
/// based on the maximum error along the radius, being equal to or less
/// than tolerance.
pub fn init(alloc: mem.Allocator, thickness: f64, tolerance: f64) !Pen {
    // You can find the proof for our calculation here in cairo-pen.c in
    // the Cairo project (https://www.cairographics.org/, MPL 1.1). It
    // shows that ultimately, the maximum error of an ellipse is along its
    // major axis, and to get our needed number of vertices, we can
    // calculate the following:
    //
    // ceil(2 * Π / acos(1 - tolerance / M))
    //
    // Where M is the major axis.
    //
    // Note that since we haven't implemented transformations yet, our only
    // axis is the radius of the circular pen (thickness / 2). Once we
    // implement transformations (TODO btw), we can adjust this to be the
    // ellipse major axis.
    const radius = thickness / 2;
    const num_vertices: usize = verts: {
        // Note that our minimum number of vertices is always 4. There are
        // also situations where our tolerance may be so high that we'd
        // have a degenerate pen, so we just return 1 in that case.
        if (tolerance >= radius * 4) {
            // Degenerate pen when our tolerance is higher than what would
            // be represented by the circle itself.
            break :verts 1;
        } else if (tolerance >= radius) {
            // Not degenerate, but can fast-path here as the tolerance is
            // so high we are going to need to represent it with the
            // minimum points anyway.
            break :verts 4;
        }

        // Calculate our delta first just in case we fall on zero for some
        // reason, and break on the minimum if it is.
        const delta = math.acos(1 - tolerance / radius);
        if (delta == 0) {
            break :verts 4;
        }

        // Regular calculation can be done now
        const n: i32 = @intFromFloat(@ceil(2 * math.pi / delta));
        if (n < 4) {
            // Below minimum
            break :verts 4;
        } else if (@rem(n, 2) != 0) {
            // Add a point for uneven vertex counts
            break :verts @intCast(n + 1);
        }

        break :verts @intCast(n);
    };

    // We can now initialize and plot our vertices
    var vertices = try std.ArrayList(PenVertex).initCapacity(alloc, num_vertices);
    errdefer vertices.deinit();

    // Add the points in a first pass
    for (0..num_vertices) |i| {
        const theta: f64 = 2 * math.pi * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(num_vertices));
        const dx = radius * @cos(theta);
        const dy = radius * @sin(theta);
        try vertices.append(.{
            .point = .{ .x = dx, .y = dy },
            .slope_cw = undefined,
            .slope_ccw = undefined,
        });
    }

    // Add the slopes in a separate pass so that we can add them relative
    // to the vertices surrounding it.
    for (0..num_vertices) |i| {
        const next = if (i >= num_vertices - 1) 0 else i + 1;
        const prev = if (i == 0) num_vertices - 1 else i - 1;
        vertices.items[i].slope_cw = Slope.init(
            vertices.items[prev].point,
            vertices.items[i].point,
        );
        vertices.items[i].slope_ccw = Slope.init(
            vertices.items[i].point,
            vertices.items[next].point,
        );
    }

    return .{
        .alloc = alloc,
        .vertices = vertices,
    };
}

pub fn deinit(self: *Pen) void {
    self.vertices.deinit();
}

/// Gets the vertices for the join range from one face to the other,
/// depending on the line direction.
///
/// The caller owns the ArrayList and must call deinit on it.
pub fn verticesForJoin(
    self: *Pen,
    from_slope: Slope,
    to_slope: Slope,
    clockwise: bool,
) !std.ArrayList(PenVertex) {
    var result = std.ArrayList(PenVertex).init(self.alloc);
    errdefer result.deinit();

    // Some of this logic was transcribed from cairo-slope.c in the Cairo
    // project (https://www.cairographics.org, MPL 1.1).
    //
    // The algorithm is basically a binary search back from the middle of
    // the vertex set. We search backwards for the vertex right after the
    // outer point of the end of the inbound face (i.e., the unjoined
    // stroke). This process is then repeated for the other direction to
    // locate the vertex right before the outer point of the start of the
    // outbound face.

    // Check the direction of the join so that we can return the
    // appropriate vertices in the correct order.
    var start: usize = 0;
    var end: usize = 0;
    const vertices_len: i32 = @intCast(self.vertices.items.len);
    if (clockwise) {
        // Clockwise join
        var low: i32 = 0;
        var high: i32 = vertices_len;
        var i: i32 = (low + high) >> 1;
        while (high - low > 1) : (i = (low + high) >> 1) {
            if (self.vertices.items[@intCast(i)].slope_cw.compare(from_slope) < 0)
                low = i
            else
                high = i;
        }

        if (self.vertices.items[@intCast(i)].slope_cw.compare(from_slope) < 0) {
            i += 1;
            if (i == vertices_len) i = 0;
        }
        start = @intCast(i);

        if (to_slope.compare(self.vertices.items[@intCast(i)].slope_ccw) >= 0) {
            low = i;
            high = i + vertices_len;
            i = (low + high) >> 1;
            while (high - low > 1) : (i = (low + high) >> 1) {
                const j: i32 = if (i >= vertices_len) i - vertices_len else i;
                if (self.vertices.items[@intCast(j)].slope_cw.compare(to_slope) > 0)
                    high = i
                else
                    low = i;
            }

            if (i >= vertices_len) i -= vertices_len;
        }

        end = @intCast(i);
    } else {
        // Counter-clockwise join
        var low: i32 = 0;
        var high: i32 = vertices_len;
        var i: i32 = (low + high) >> 1;
        while (high - low > 1) : (i = (low + high) >> 1) {
            if (from_slope.compare(self.vertices.items[@intCast(i)].slope_ccw) < 0)
                low = i
            else
                high = i;
        }

        if (from_slope.compare(self.vertices.items[@intCast(i)].slope_ccw) < 0) {
            i += 1;
            if (i == vertices_len) i = 0;
        }
        start = @intCast(i);

        if (self.vertices.items[@intCast(i)].slope_cw.compare(to_slope) <= 0) {
            low = i;
            high = i + vertices_len;
            i = (low + high) >> 1;
            while (high - low > 1) : (i = (low + high) >> 1) {
                const j: i32 = if (i >= vertices_len) i - vertices_len else i;
                if (to_slope.compare(self.vertices.items[@intCast(j)].slope_ccw) > 0)
                    high = i
                else
                    low = i;
            }

            if (i >= vertices_len) i -= vertices_len;
        }

        end = @intCast(i);
    }

    var idx = start;
    if (clockwise) {
        while (idx != end) : ({
            idx += 1;
            if (idx == vertices_len) idx = 0;
        }) {
            try result.append(self.vertices.items[idx]);
        }
    } else {
        while (idx != end) : ({
            if (idx == 0) idx = @intCast(vertices_len);
            idx -= 1;
        }) {
            try result.append(self.vertices.items[idx]);
        }
    }

    return result;
}
