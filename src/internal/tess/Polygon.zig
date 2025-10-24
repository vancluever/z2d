const Polygon = @This();

const std = @import("std");
const debug = @import("std").debug;
const heap = @import("std").heap;
const math = @import("std").math;
const mem = @import("std").mem;
const stdSort = @import("std").sort;
const testing = @import("std").testing;

const FillRule = @import("../../options.zig").FillRule;
const InternalError = @import("../InternalError.zig").InternalError;
const Point = @import("../Point.zig");

const runCases = @import("../util.zig").runCases;
const TestingError = @import("../util.zig").TestingError;

pub const Edge = struct {
    y0: f64,
    y1: f64,
    x_start: f64,
    x_inc: f64,

    fn dir(self: *const Edge) i2 {
        if (self.y0 < self.y1) {
            return -1;
        }

        return 1;
    }

    fn top(self: *const Edge) f64 {
        if (self.y0 < self.y1) {
            return self.y0;
        }

        return self.y1;
    }

    fn bottom(self: *const Edge) f64 {
        if (self.y0 < self.y1) {
            return self.y1;
        }

        return self.y0;
    }
};

edges: std.ArrayListUnmanaged(Edge) = .empty,
scale: f64 = 1, // NOTE: Only needs to be set if adding edges directly (not from contours)
extent_top: f64 = 0.0,
extent_bottom: f64 = 0.0,
extent_left: f64 = 0.0,
extent_right: f64 = 0.0,

pub fn deinit(self: *Polygon, alloc: mem.Allocator) void {
    self.edges.deinit(alloc);
    self.* = undefined;
}

pub fn addEdge(
    self: *Polygon,
    alloc: mem.Allocator,
    p0: Point,
    p1: Point,
) mem.Allocator.Error!void {
    // assert for NaNs
    debug.assert(math.isFinite(p0.x) and math.isFinite(p0.y));
    debug.assert(math.isFinite(p1.x) and math.isFinite(p1.y));
    const p0_scaled: Point = .{ .x = p0.x * self.scale, .y = p0.y * self.scale };
    const p1_scaled: Point = .{ .x = p1.x * self.scale, .y = p1.y * self.scale };

    const edge: Edge = if (p0_scaled.y < p1_scaled.y) .{
        // Down edge
        .y0 = p0_scaled.y,
        .y1 = p1_scaled.y,
        .x_start = p0_scaled.x,
        .x_inc = (p1_scaled.x - p0_scaled.x) / (p1_scaled.y - p0_scaled.y),
    } else if (p0_scaled.y > p1_scaled.y) .{
        // Up edge
        .y0 = p0_scaled.y,
        .y1 = p1_scaled.y,
        .x_start = p1_scaled.x,
        .x_inc = (p0_scaled.x - p1_scaled.x) / (p0_scaled.y - p1_scaled.y),
    } else {
        return; // Filter out horizontal edges
    };

    // Check extents
    const extent_top = edge.top();
    const extent_bottom = edge.bottom();
    const extent_left, const extent_right = if (p0_scaled.x < p1_scaled.x)
        .{ p0_scaled.x, p1_scaled.x }
    else
        .{ p1_scaled.x, p0_scaled.x };
    if (self.edges.items.len == 0) {
        self.extent_top = extent_top;
        self.extent_bottom = extent_bottom;
        self.extent_left = extent_left;
        self.extent_right = extent_right;
    } else {
        if (extent_top < self.extent_top) self.extent_top = extent_top;
        if (extent_bottom > self.extent_bottom) self.extent_bottom = extent_bottom;
        if (extent_left < self.extent_left) self.extent_left = extent_left;
        if (extent_right > self.extent_right) self.extent_right = extent_right;
    }

    try self.edges.append(alloc, edge);
}

/// Iterate over the supplied contour and add each individual line as an edge.
///
/// Note this does not de-initialize the contour, so deinit needs to be called
/// after it if that's the intent.
pub fn addEdgesFromContour(
    self: *Polygon,
    alloc: mem.Allocator,
    contour: Contour,
) mem.Allocator.Error!void {
    var node_ = contour.corners.first;
    var initial_point_: ?Point = null;
    var last_point_: ?Point = null;
    while (node_) |node| {
        const current_point = Contour.Corner.fromNode(node).point;
        if (initial_point_ == null) initial_point_ = current_point;
        if (last_point_) |last_point| {
            try self.addEdge(alloc, last_point, current_point);
        }
        last_point_ = current_point;
        node_ = node.next;
    }
    if (initial_point_) |initial_point| {
        if (last_point_) |last_point| {
            try self.addEdge(alloc, last_point, initial_point);
        }
    }
}

/// Returns true if our polygon list is somewhere within the box starting at
/// (0,0) with the width box_width and the height box_height. Used to check if
/// we should actually proceed with drawing.
pub fn inBox(self: *const Polygon, scale: f64, box_width: i32, box_height: i32) bool {
    if (!math.isFinite(self.extent_left) or !math.isFinite(self.extent_top) or
        !math.isFinite(self.extent_right) or !math.isFinite(self.extent_bottom))
    {
        @panic("invalid polygon dimensions. this is a bug, please report it");
    }

    if (!math.isFinite(scale) or scale < 1.0) {
        @panic("invalid value for scale. this is a bug, please report it");
    }

    if (box_width < 1 or box_height < 1) {
        @panic("invalid box width or height. this is a bug, please report it");
    }

    // Round our polygon to the appropriate dimensions. For scanline fill, we
    // make sure to push our our box so the whole of the polygon fits in
    // the box.
    const poly_start_x: i32 = @intFromFloat(@floor(self.extent_left / scale));
    const poly_start_y: i32 = @intFromFloat(@floor(self.extent_top / scale));
    const poly_end_x: i32 = @intFromFloat(@ceil(self.extent_right / scale));
    const poly_end_y: i32 = @intFromFloat(@ceil(self.extent_bottom / scale));

    // Our polygon width and height
    const poly_width: i32 = poly_end_x - poly_start_x;
    const poly_height: i32 = poly_end_y - poly_start_y;

    // If this happens, there's an error in our polygon plotting.
    if (poly_width < 0 or poly_height < 0) {
        @panic("negative polygon width or height. this is a bug, please report it");
    }

    // If one of our width or height are zero, nothing drawable was
    // ultimately plotted, possibly a degenerate case.
    if (poly_width == 0 or poly_height == 0) {
        return false;
    }

    // Check the upper-left of our drawing area to make sure, that in the case
    // of negative start offsets, we actually reach into the surface. If we
    // don't (i.e., if it's not wide or high enough), we're not in the box.
    if (poly_start_x + poly_width < 0 or poly_start_y + poly_height < 0) {
        return false;
    }

    // Finally, if our start co-ordinates are outside the right or upper
    // bounds of the surface, we're not in the box.
    if (poly_start_x >= box_width or poly_start_y >= box_height) {
        return false;
    }

    // We're in the box.
    return true;
}

pub const WorkingEdgeSet = struct {
    polygon: *const Polygon,
    edges: []Edge,
    x_values: []i32,

    pub fn init(alloc: mem.Allocator, polygon: *const Polygon) mem.Allocator.Error!WorkingEdgeSet {
        // Allocate our scratch space for the whole of the length of the
        // polygon edges. Note that we re-slice this often, so the source of
        // truth for the length here is the actual number of polygon edges,
        // which is const in the context of the working edge table; although we
        // do re-order the edges, the number of them does not change.
        const x_values_full = try alloc.alloc(i32, polygon.edges.items.len);
        // Initialize the edges and x-value scratch space empty (implying an
        // empty working edge set to start).
        return .{
            .polygon = polygon,
            .edges = polygon.edges.items[0..0],
            .x_values = x_values_full[0..0],
        };
    }

    pub fn deinit(self: *WorkingEdgeSet, alloc: mem.Allocator) void {
        // Reset the x-value scratch space to the full edge length before
        // freeing.
        self.x_values.len = self.polygon.edges.items.len;
        alloc.free(self.x_values);
        self.* = undefined;
    }

    pub fn breakpoints(
        self: *WorkingEdgeSet,
        alloc: mem.Allocator,
    ) mem.Allocator.Error!std.ArrayListUnmanaged(i32) {
        const InsertFn = struct {
            fn f(
                insert_alloc: mem.Allocator,
                insert_list: *std.ArrayListUnmanaged(i32),
                insert_value: i32,
            ) mem.Allocator.Error!void {
                if (insert_list.items.len == 0) return insert_list.append(insert_alloc, insert_value);

                var low: usize = 0;
                var high: usize = insert_list.items.len;

                while (low < high) {
                    const mid = low + (high - low) / 2;
                    if (insert_list.items[mid] < insert_value) {
                        low = mid + 1;
                    } else {
                        high = mid;
                    }
                }

                const insertion_idx = low;
                if (insertion_idx == insert_list.items.len) {
                    return insert_list.append(insert_alloc, insert_value);
                } else if (insert_list.items[insertion_idx] != insert_value) {
                    return insert_list.insert(insert_alloc, insertion_idx, insert_value);
                }
            }
        };

        var result: std.ArrayListUnmanaged(i32) = try .initCapacity(alloc, self.polygon.edges.items.len * 2);
        errdefer result.deinit(alloc);
        for (self.polygon.edges.items) |e| {
            try InsertFn.f(alloc, &result, @intFromFloat(@round(e.top())));
            try InsertFn.f(alloc, &result, @intFromFloat(@round(e.bottom())));
        }

        return result;
    }

    pub fn rescan(self: *WorkingEdgeSet, line_y: i32) void {
        if (self.polygon.edges.items.len == 0) return;

        // We take our line measurements at the middle of the line; this helps
        // "break the tie" with lines that fall exactly on point boundaries.
        const line_y_middle = @as(f64, @floatFromInt(line_y)) + 0.5;

        var to: usize = 0;
        for (0..self.polygon.edges.items.len) |from| {
            if (self.polygon.edges.items[from].top() < line_y_middle and
                self.polygon.edges.items[from].bottom() >= line_y_middle)
            {
                if (from != to) mem.swap(
                    Edge,
                    &self.polygon.edges.items[to],
                    &self.polygon.edges.items[from],
                );
                to += 1;
            }
        }

        self.edges = self.polygon.edges.items[0..to];
        self.x_values.len = to;

        debug.assert(self.edges.len == self.x_values.len);
    }

    pub fn inc(self: *WorkingEdgeSet, y: i32) void {
        const y_mid: f64 = @as(f64, @floatFromInt(y)) + 0.5;
        for (self.edges, 0..) |edge, idx| {
            self.x_values[idx] = @intFromFloat(@round(edge.x_start + (edge.x_inc * (y_mid - edge.top()))));
        }
    }

    pub fn sort(self: *WorkingEdgeSet) void {
        const Context = struct {
            s: *WorkingEdgeSet,

            pub fn lessThan(ctx: @This(), a: usize, b: usize) bool {
                return ctx.s.x_values[a] < ctx.s.x_values[b];
            }

            pub fn swap(ctx: @This(), a: usize, b: usize) void {
                mem.swap(Edge, &ctx.s.edges[a], &ctx.s.edges[b]);
                mem.swap(i32, &ctx.s.x_values[a], &ctx.s.x_values[b]);
            }
        };

        stdSort.pdqContext(0, self.x_values.len, Context{ .s = self });
    }

    pub fn filter(self: *WorkingEdgeSet, fill_rule: FillRule) []i32 {
        // In-place filter depending on the fill rule (even-odd is just pass-thru).
        switch (fill_rule) {
            .even_odd => return self.x_values,
            .non_zero => {
                // Before returning, filter in-place based on winding rule;
                // consecutive edges in the same direction are filtered out after
                // the first one, so that only one set of each direction happens
                // one after the other.
                var winding_number: i32 = 0;
                var to: usize = 0;
                for (0..self.x_values.len) |from| {
                    self.x_values[to] = self.x_values[from];
                    if (winding_number == 0) {
                        winding_number += self.edges[from].dir();
                        to += 1;
                    } else {
                        winding_number += self.edges[from].dir();
                        if (winding_number == 0) {
                            to += 1;
                        }
                    }
                }

                return self.x_values[0..to];
            },
        }
    }
};

/// Represents a polyline (contour) that will be later assembled into a
/// polygon, or converted to a set of edges to be added to a larger
/// polygon/edge collection.
pub const Contour = struct {
    pub const Corner = struct {
        point: Point,
        node: std.DoublyLinkedList.Node = .{},

        pub fn fromNode(n: *std.DoublyLinkedList.Node) *Corner {
            return @alignCast(@fieldParentPtr("node", n));
        }
    };

    len: usize = 0,
    corners: std.DoublyLinkedList = .{},
    scale: f64,

    pub fn deinit(self: *Contour, alloc: mem.Allocator) void {
        var node_ = self.corners.first;
        while (node_) |node| {
            node_ = node.next;
            alloc.destroy(Contour.Corner.fromNode(node));
        }
        self.* = undefined;
    }

    /// Plots a point on the contour. If before is specified, the point is
    /// plotted before it.
    pub fn plot(
        self: *Contour,
        alloc: mem.Allocator,
        point: Point,
        before_: ?*std.DoublyLinkedList.Node,
    ) mem.Allocator.Error!void {
        debug.assert(math.isFinite(point.x) and math.isFinite(point.y));
        const scaled: Point = .{
            .x = point.x * self.scale,
            .y = point.y * self.scale,
        };

        const n = try alloc.create(Corner);
        n.* = .{
            .point = scaled,
        };
        if (before_) |before| self.corners.insertBefore(before, &n.node) else self.corners.append(&n.node);
        self.len += 1;
    }

    /// Like plot, but adds points in the reverse direction (i.e., at the start of
    /// the polygon instead of the end.
    pub fn plotReverse(self: *Contour, alloc: mem.Allocator, point: Point) mem.Allocator.Error!void {
        debug.assert(math.isFinite(point.x) and math.isFinite(point.y));
        const scaled: Point = .{
            .x = point.x * self.scale,
            .y = point.y * self.scale,
        };

        const n = try alloc.create(Corner);
        n.* = .{
            .point = scaled,
        };
        self.corners.prepend(&n.node);
        self.len += 1;
    }

    /// Concatenates a contour into this one and detaches its contours from its
    /// linked list.
    pub fn concat(self: *Contour, other: *Contour) void {
        // concatByMoving will reset the other list to an empty list, so we
        // don't need to do it ourselves.
        self.corners.concatByMoving(&other.corners);
        self.len += other.len;
        other.len = 0;
    }
};

test "Polygon.inBox" {
    const name = "Polygon.inBox";
    const cases = [_]struct {
        name: []const u8,
        polygon: Polygon,
        scale: f64,
        box_width: i32,
        box_height: i32,
        expected: bool,
    }{
        .{
            .name = "basic",
            .polygon = .{
                .extent_left = 10.0,
                .extent_top = 10.0,
                .extent_right = 20.0,
                .extent_bottom = 20.0,
            },
            .scale = 1.0,
            .box_height = 30,
            .box_width = 30,
            .expected = true,
        },
        .{
            .name = "overlap, upper",
            .polygon = .{
                .extent_left = 2.5,
                .extent_top = -5.0,
                .extent_right = 7.5,
                .extent_bottom = 5.0,
            },
            .scale = 1.0,
            .box_height = 10,
            .box_width = 10,
            .expected = true,
        },
        .{
            .name = "overlap, lower",
            .polygon = .{
                .extent_left = 2.5,
                .extent_top = 5.0,
                .extent_right = 7.5,
                .extent_bottom = 15.0,
            },
            .scale = 1.0,
            .box_height = 10,
            .box_width = 10,
            .expected = true,
        },
        .{
            .name = "overlap, left",
            .polygon = .{
                .extent_left = -5.0,
                .extent_top = 2.5,
                .extent_right = 5.0,
                .extent_bottom = 7.5,
            },
            .scale = 1.0,
            .box_height = 10,
            .box_width = 10,
            .expected = true,
        },
        .{
            .name = "overlap, right",
            .polygon = .{
                .extent_left = 5.0,
                .extent_top = 2.5,
                .extent_right = 15.0,
                .extent_bottom = 7.5,
            },
            .scale = 1.0,
            .box_height = 10,
            .box_width = 10,
            .expected = true,
        },
        .{
            .name = "overlap, upper left",
            .polygon = .{
                .extent_left = -5.0,
                .extent_top = -5.0,
                .extent_right = 5.0,
                .extent_bottom = 5.0,
            },
            .scale = 1.0,
            .box_height = 10,
            .box_width = 10,
            .expected = true,
        },
        .{
            .name = "overlap, upper right",
            .polygon = .{
                .extent_left = 5.0,
                .extent_top = -5.0,
                .extent_right = 15.0,
                .extent_bottom = 5.0,
            },
            .scale = 1.0,
            .box_height = 10,
            .box_width = 10,
            .expected = true,
        },
        .{
            .name = "overlap, lower left",
            .polygon = .{
                .extent_left = -5.0,
                .extent_top = 5.0,
                .extent_right = 5.0,
                .extent_bottom = 15.0,
            },
            .scale = 1.0,
            .box_height = 10,
            .box_width = 10,
            .expected = true,
        },
        .{
            .name = "overlap, lower right",
            .polygon = .{
                .extent_left = 5.0,
                .extent_top = 5.0,
                .extent_right = 15.0,
                .extent_bottom = 15.0,
            },
            .scale = 1.0,
            .box_height = 10,
            .box_width = 10,
            .expected = true,
        },
        .{
            .name = "OOB, upper",
            .polygon = .{
                .extent_left = 2.5,
                .extent_top = -15.0,
                .extent_right = 7.5,
                .extent_bottom = -5.0,
            },
            .scale = 1.0,
            .box_height = 10,
            .box_width = 10,
            .expected = false,
        },
        .{
            .name = "OOB, lower",
            .polygon = .{
                .extent_left = 2.5,
                .extent_top = 15.0,
                .extent_right = 7.5,
                .extent_bottom = 25.0,
            },
            .scale = 1.0,
            .box_height = 10,
            .box_width = 10,
            .expected = false,
        },
        .{
            .name = "OOB, left",
            .polygon = .{
                .extent_left = -15.0,
                .extent_top = 2.5,
                .extent_right = -5.0,
                .extent_bottom = 7.5,
            },
            .scale = 1.0,
            .box_height = 10,
            .box_width = 10,
            .expected = false,
        },
        .{
            .name = "OOB, right",
            .polygon = .{
                .extent_left = 15.0,
                .extent_top = 2.5,
                .extent_right = 25.0,
                .extent_bottom = 7.5,
            },
            .scale = 1.0,
            .box_height = 10,
            .box_width = 10,
            .expected = false,
        },
        .{
            .name = "OOB, upper left",
            .polygon = .{
                .extent_left = -20.0,
                .extent_top = -20.0,
                .extent_right = -10.0,
                .extent_bottom = -10.0,
            },
            .scale = 1.0,
            .box_height = 10,
            .box_width = 10,
            .expected = false,
        },
        .{
            .name = "OOB, upper right",
            .polygon = .{
                .extent_left = 20.0,
                .extent_top = -20.0,
                .extent_right = 30.0,
                .extent_bottom = -10.0,
            },
            .scale = 1.0,
            .box_height = 10,
            .box_width = 10,
            .expected = false,
        },
        .{
            .name = "OOB, lower left",
            .polygon = .{
                .extent_left = -20.0,
                .extent_top = 20.0,
                .extent_right = -10.0,
                .extent_bottom = 30.0,
            },
            .scale = 1.0,
            .box_height = 10,
            .box_width = 10,
            .expected = false,
        },
        .{
            .name = "OOB, lower right",
            .polygon = .{
                .extent_left = 20.0,
                .extent_top = 20.0,
                .extent_right = 30.0,
                .extent_bottom = 30.0,
            },
            .scale = 1.0,
            .box_height = 10,
            .box_width = 10,
            .expected = false,
        },
        .{
            .name = "scale",
            .polygon = .{
                .extent_left = 20.0,
                .extent_top = 20.0,
                .extent_right = 60.0,
                .extent_bottom = 60.0,
            },
            .scale = 4.0,
            .box_height = 10,
            .box_width = 10,
            .expected = true,
        },
        .{
            .name = "degenerate x axis",
            .polygon = .{
                .extent_left = 5.0,
                .extent_top = 2.5,
                .extent_right = 5.0,
                .extent_bottom = 7.5,
            },
            .scale = 1.0,
            .box_height = 10,
            .box_width = 10,
            .expected = false,
        },
        .{
            .name = "degenerate y axis",
            .polygon = .{
                .extent_left = 2.5,
                .extent_top = 5.0,
                .extent_right = 7.5,
                .extent_bottom = 5.0,
            },
            .scale = 1.0,
            .box_height = 10,
            .box_width = 10,
            .expected = false,
        },
        .{
            .name = "rounding into upper left, x-axis",
            .polygon = .{
                .extent_left = -2.0,
                .extent_top = -2.0,
                .extent_right = -0.75,
                .extent_bottom = 0.0,
            },
            .scale = 1.0,
            .box_height = 10,
            .box_width = 10,
            .expected = true,
        },
        .{
            .name = "rounding into upper left, y-axis",
            .polygon = .{
                .extent_left = -2.0,
                .extent_top = -2.0,
                .extent_right = 0.0,
                .extent_bottom = -0.75,
            },
            .scale = 1.0,
            .box_height = 10,
            .box_width = 10,
            .expected = true,
        },
        .{
            .name = "rounding into lower right, x-axis",
            .polygon = .{
                .extent_left = 9.5,
                .extent_top = 9.0,
                .extent_right = 11.0,
                .extent_bottom = 11.0,
            },
            .scale = 1.0,
            .box_height = 10,
            .box_width = 10,
            .expected = true,
        },
        .{
            .name = "rounding into lower right, y-axis",
            .polygon = .{
                .extent_left = 9.0,
                .extent_top = 9.5,
                .extent_right = 11.0,
                .extent_bottom = 11.0,
            },
            .scale = 1.0,
            .box_height = 10,
            .box_width = 10,
            .expected = true,
        },
    };
    const TestFn = struct {
        fn f(tc: anytype) TestingError!void {
            try testing.expectEqualDeep(
                tc.expected,
                tc.polygon.inBox(tc.scale, tc.box_height, tc.box_width),
            );
        }
    };
    try runCases(name, cases, TestFn.f);
}
