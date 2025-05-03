// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024-2025 Chris Marchesi
//   Copyright © 2002 University of Southern California
//
// Portions of the code in this file have been derived and adapted from the
// Cairo project (https://www.cairographics.org/), notably cairo-pen.c.

//! A Pen represents a circular area designed for specific stroking operations,
//! such as round joins and caps.
const Pen = @This();

const std = @import("std");
const math = @import("std").math;
const mem = @import("std").mem;

const arc = @import("arc.zig");
const Face = @import("Face.zig");
const Point = @import("Point.zig");
const Slope = @import("Slope.zig");
const Transformation = @import("../Transformation.zig");

const PenVertex = struct {
    point: Point,
    slope_cw: Slope,
    slope_ccw: Slope,
};

/// The vertices, centered around (0,0) and distributed on even angles
/// around the pen.
vertices: std.ArrayListUnmanaged(PenVertex),

/// Initializes a pen at radius thickness / 2, with point distribution
/// based on the maximum error along the radius, being equal to or less
/// than tolerance.
pub fn init(
    alloc: mem.Allocator,
    thickness: f64,
    tolerance: f64,
    ctm: Transformation,
) mem.Allocator.Error!Pen {
    // You can find the proof for our calculation here in cairo-pen.c in the
    // Cairo project. It shows that ultimately, the maximum error of an ellipse
    // is along its major axis, and to get our needed number of vertices, we
    // can calculate the following:
    //
    // ceil(2 * Π / acos(1 - tolerance / M))
    //
    // Where M is the major axis.
    const radius = thickness / 2;
    const num_vertices: i32 = verts: {
        const major_axis: f64 = arc.transformed_circle_major_axis(ctm, radius);
        // Note that our minimum number of vertices is always 4. There are
        // also situations where our tolerance may be so high that we'd
        // have a degenerate pen, so we just return 1 in that case.
        if (tolerance >= major_axis * 4) {
            // Degenerate pen when our tolerance is higher than what would
            // be represented by the circle itself.
            break :verts 1;
        } else if (tolerance >= major_axis) {
            // Not degenerate, but can fast-path here as the tolerance is
            // so high we are going to need to represent it with the
            // minimum points anyway.
            break :verts 4;
        }

        // Calculate our delta first just in case we fall on zero for some
        // reason, and break on the minimum if it is.
        const delta = math.acos(1 - tolerance / major_axis);
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
            break :verts n + 1;
        }

        break :verts n;
    };

    // We can now initialize and plot our vertices
    var vertices = try std.ArrayListUnmanaged(PenVertex).initCapacity(alloc, @max(0, num_vertices));
    errdefer vertices.deinit(alloc);

    // Add the points in a first pass. Note our baseline for determining points
    // is user space (as we're just plotting a circle, so we need to transform
    // off our ctm to get the correct ellipse for the pen.
    const reflect = ctm.determinant() < 0;
    for (0..@max(0, num_vertices)) |i| {
        const theta: f64 = th: {
            var t = 2 * math.pi * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(num_vertices));
            if (reflect) t = -t;
            break :th t;
        };
        var dx = radius * @cos(theta);
        var dy = radius * @sin(theta);
        ctm.userToDeviceDistance(&dx, &dy);
        try vertices.append(alloc, .{
            .point = .{ .x = dx, .y = dy },
            .slope_cw = undefined,
            .slope_ccw = undefined,
        });
    }

    // Add the slopes in a separate pass so that we can add them relative
    // to the vertices surrounding it.
    for (0..@max(0, num_vertices)) |i| {
        const next: usize = if (i >= num_vertices - 1) 0 else i + 1;
        const prev: usize = @max(0, if (i == 0) num_vertices - 1 else @as(i32, @intCast(i)) - 1);
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
        .vertices = vertices,
    };
}

pub fn deinit(self: *Pen, alloc: mem.Allocator) void {
    self.vertices.deinit(alloc);
}

/// Returns an iterator for the vertex range from one face to the other,
/// depending on the line direction.
pub fn vertexIteratorFor(
    self: *const Pen,
    from_slope: Slope,
    to_slope: Slope,
    clockwise: bool,
) VertexIterator {
    // The algorithm is basically a binary search back from the middle of
    // the vertex set. We search backwards for the vertex right after the
    // outer point of the end of the inbound face (i.e., the unjoined
    // stroke). This process is then repeated for the other direction to
    // locate the vertex right before the outer point of the start of the
    // outbound face.

    // Check the direction of the join so that we can return the
    // appropriate vertices in the correct order.
    var start: i32 = 0;
    var end: i32 = 0;
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
        start = i;

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

        end = i;
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
        start = i;

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

        end = i;
    }

    return .{
        .pen = self,
        .end = @max(0, end),
        .idx = @max(0, start),
        .clockwise = clockwise,
    };
}

const VertexIterator = struct {
    pen: *const Pen,
    end: usize,
    idx: usize,
    clockwise: bool,

    pub fn next(self: *VertexIterator) ?PenVertex {
        if (self.idx == self.end) return null;
        if (self.clockwise) {
            const result = self.pen.vertices.items[self.idx];
            self.idx += 1;
            if (self.idx == self.pen.vertices.items.len) self.idx = 0;
            return result;
        } else {
            const result = self.pen.vertices.items[self.idx];
            if (self.idx == 0) self.idx = self.pen.vertices.items.len;
            self.idx -= 1;
            return result;
        }
    }
};
