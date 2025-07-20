const Polygon = @This();

const std = @import("std");
const debug = @import("std").debug;
const math = @import("std").math;
const mem = @import("std").mem;
const testing = @import("std").testing;

const FillRule = @import("../options.zig").FillRule;
const Point = @import("Point.zig");
const InternalError = @import("InternalError.zig").InternalError;
const edge_buffer_size = @import("../painter.zig").edge_buffer_size;

const runCases = @import("util.zig").runCases;
const TestingError = @import("util.zig").TestingError;

pub const Edge = struct {
    top: f64,
    bottom: f64,
    x_start: f64,
    x_inc: f64,
    dir: i2,
};

edges: std.ArrayListUnmanaged(Edge) = .empty,
scale: f64 = 1, // NOTE: Only needs to be set if adding edges directly (not from contours)
extent_top: f64 = 0.0,
extent_bottom: f64 = 0.0,
extent_left: f64 = 0.0,
extent_right: f64 = 0.0,

pub fn deinit(self: *Polygon, alloc: mem.Allocator) void {
    self.edges.deinit(alloc);
    self.edges = .{};
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
        .top = p0_scaled.y,
        .bottom = p1_scaled.y,
        .x_start = p0_scaled.x,
        .x_inc = (p1_scaled.x - p0_scaled.x) / (p1_scaled.y - p0_scaled.y),
        .dir = -1,
    } else if (p0_scaled.y > p1_scaled.y) .{
        // Up edge
        .top = p1_scaled.y,
        .bottom = p0_scaled.y,
        .x_start = p1_scaled.x,
        .x_inc = (p0_scaled.x - p1_scaled.x) / (p0_scaled.y - p1_scaled.y),
        .dir = 1,
    } else {
        return; // Filter out horizontal edges
    };

    // Check extents
    const extent_top = edge.top;
    const extent_bottom = edge.bottom;
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
        if (initial_point_ == null) initial_point_ = node.data;
        if (last_point_) |last_point| {
            try self.addEdge(alloc, last_point, node.data);
        }
        last_point_ = node.data;
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

/// Represents an x-edge on a polygon for a particular y-scanline.
pub const XEdge = packed struct {
    // The size of our x-edge.
    //
    // TODO: This ultimately places a limit on our edge size to i30 currently
    // (approx. +/- 536870912). This is set up to ensure this struct fits in a
    // u32 as this our edges are stored in a very small buffer.
    //
    // Note that our internal numerics are not 100% yet decided on, so this
    // limit may change (and will likely decrease versus increase).
    pub const X = i30;

    x: X,
    dir: i2,

    pub fn sort_asc(_: void, a: XEdge, b: XEdge) bool {
        return a.x < b.x;
    }
};

pub const XEdgeListIterator = struct {
    index: usize = 0,
    edges: []XEdge = &.{},
    fill_rule: FillRule = .non_zero,

    pub const EdgePair = struct {
        start: i32,
        end: i32,
    };

    pub fn deinit(it: *XEdgeListIterator, alloc: mem.Allocator) void {
        alloc.free(it.edges);
        it.edges = undefined;
    }

    pub fn next(it: *XEdgeListIterator) ?EdgePair {
        debug.assert(it.index <= it.edges.len);
        if (it.edges.len == 0 or it.index >= it.edges.len - 1) return null;
        if (it.fill_rule == .even_odd) {
            const start = it.edges[it.index].x;
            const end = it.edges[it.index + 1].x;
            it.index += 2;
            return .{
                .start = start,
                .end = end,
            };
        } else {
            var winding_number: i32 = 0;
            var start: i32 = undefined;
            while (it.index < it.edges.len) : (it.index += 1) {
                if (winding_number == 0) {
                    start = it.edges[it.index].x;
                }
                winding_number += @intCast(it.edges[it.index].dir);
                if (winding_number == 0) {
                    const end = it.edges[it.index].x;
                    it.index += 1;
                    return .{
                        .start = start,
                        .end = end,
                    };
                }
            }
        }

        return null;
    }
};

pub fn xEdgesForY(
    self: *const Polygon,
    alloc: mem.Allocator,
    line_y: f64,
    fill_rule: FillRule,
) mem.Allocator.Error!XEdgeListIterator {
    if (self.edges.items.len == 0) return .{};

    const edge_list_capacity = edge_buffer_size / @sizeOf(XEdge);
    var edge_list = try std.ArrayListUnmanaged(XEdge).initCapacity(alloc, edge_list_capacity);
    defer edge_list.deinit(alloc);

    // We take our line measurements at the middle of the line; this helps
    // "break the tie" with lines that fall exactly on point boundaries.
    debug.assert(@floor(line_y) == line_y);
    const line_y_middle = line_y + 0.5;

    for (self.edges.items) |current_edge| {
        if (current_edge.top < line_y_middle and current_edge.bottom >= line_y_middle) {
            try edge_list.append(alloc, .{
                .x = @intFromFloat(math.clamp(
                    @round(current_edge.x_start + current_edge.x_inc * (line_y_middle - current_edge.top)),
                    0,
                    math.maxInt(XEdge.X),
                )),
                .dir = current_edge.dir,
            });
        }
    }

    // Sort our edges
    const edge_list_sorted = try edge_list.toOwnedSlice(alloc);
    mem.sort(XEdge, edge_list_sorted, {}, XEdge.sort_asc);

    // Return the iterator directly from here. Previous versions of this would
    // wrap this further into another set of individual polygons, but our new
    // approach just deals in raw edges not associated with any particular
    // polygon.
    return .{
        .edges = edge_list_sorted,
        .fill_rule = fill_rule,
    };
}

/// Represents a polyline (contour) that will be later assembled into a
/// polygon, or converted to a set of edges to be added to a larger
/// polygon/edge collection.
pub const Contour = struct {
    pub const CornerList = std.DoublyLinkedList(Point);

    corners: CornerList = .{},
    scale: f64,

    pub fn deinit(self: *Contour, alloc: mem.Allocator) void {
        var node_ = self.corners.first;
        while (node_) |node| {
            node_ = node.next;
            alloc.destroy(node);
        }
        self.corners = .{};
    }

    /// Plots a point on the contour. If before is specified, the point is
    /// plotted before it.
    pub fn plot(
        self: *Contour,
        alloc: mem.Allocator,
        point: Point,
        before_: ?*CornerList.Node,
    ) mem.Allocator.Error!void {
        debug.assert(math.isFinite(point.x) and math.isFinite(point.y));
        const scaled: Point = .{
            .x = point.x * self.scale,
            .y = point.y * self.scale,
        };

        const n = try alloc.create(CornerList.Node);
        n.* = .{
            .data = scaled,
        };
        if (before_) |before| self.corners.insertBefore(before, n) else self.corners.append(n);
    }

    /// Like plot, but adds points in the reverse direction (i.e., at the start of
    /// the polygon instead of the end.
    pub fn plotReverse(self: *Contour, alloc: mem.Allocator, point: Point) mem.Allocator.Error!void {
        debug.assert(math.isFinite(point.x) and math.isFinite(point.y));
        const n = try alloc.create(CornerList.Node);

        const scaled: Point = .{
            .x = point.x * self.scale,
            .y = point.y * self.scale,
        };

        n.* = .{
            .data = scaled,
        };
        self.corners.prepend(n);
    }

    /// Concatenates a contour into this one. It's invalid to use the other contour
    /// after this operation is done.
    pub fn concat(self: *Contour, other: *Contour) void {
        // concatByMoving will reset the other list to an empty list, so we
        // don't need to do it ourselves.
        self.corners.concatByMoving(&other.corners);
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

test "xEdgesForY, prevent i30 overflow" {
    const alloc = testing.allocator;
    var polygon: Polygon = .{};
    defer polygon.deinit(alloc);
    try polygon.addEdge(alloc, .{ .x = 600000100, .y = 600000100 }, .{ .x = 600000050, .y = 600000200 });
    try polygon.addEdge(alloc, .{ .x = 600000050, .y = 600000200 }, .{ .x = 600000000, .y = 600000100 });
    // Don't need a result here, just needs to actually work and not overflow
    var x_edges = try polygon.xEdgesForY(alloc, 600000150, .non_zero);
    defer x_edges.deinit(alloc);
}
