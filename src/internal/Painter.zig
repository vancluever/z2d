//! Painter represents the internal code related to painting (fill/stroke/etc).
const Painter = @This();

const std = @import("std");
const debug = @import("std").debug;
const heap = @import("std").heap;
const math = @import("std").math;
const mem = @import("std").mem;

const fill_plotter = @import("FillPlotter.zig");

const Context = @import("../Context.zig");
const PathNode = @import("path_nodes.zig").PathNode;
const RGBA = @import("../pixel.zig").RGBA;
const Surface = @import("../surface.zig").Surface;
const FillRule = @import("../options.zig").FillRule;
const StrokePlotter = @import("StrokePlotter.zig");
const PolygonList = @import("PolygonList.zig");
const supersample_scale = @import("../surface.zig").supersample_scale;

/// The reference to the context that we use for painting operations.
context: *Context,

/// Runs a fill operation on this current path and any subpaths.
pub fn fill(
    self: *const Painter,
    alloc: mem.Allocator,
    nodes: std.ArrayList(PathNode),
) !void {
    // There should be a minimum of two nodes in anything passed here.
    // Additionally, the higher-level path API also always adds an explicit
    // move_to after close_path nodes, so we assert on this.
    //
    // NOTE: obviously, to be useful, there would be much more than two nodes,
    // but this is just the minimum for us to assert that the path has been
    // closed correctly.
    if (nodes.items.len < 2) return error.InvalidPathData;
    if (nodes.items[nodes.items.len - 2] != .close_path) return error.InvalidPathData;
    if (nodes.getLast() != .move_to) return error.InvalidPathData;

    const scale: f64 = switch (self.context.anti_aliasing_mode) {
        .none => 1,
        .default => supersample_scale,
    };

    var polygons = try fill_plotter.plot(alloc, nodes, scale);
    defer polygons.deinit();

    switch (self.context.anti_aliasing_mode) {
        .none => {
            try self.paintDirect(alloc, polygons, self.context.fill_rule);
        },
        .default => {
            try self.paintComposite(alloc, polygons, self.context.fill_rule, scale);
        },
    }
}

/// Runs a stroke operation on this path and any sub-paths. The path is
/// transformed to a fillable polygon representing the line, and the line is
/// then filled.
pub fn stroke(
    self: *const Painter,
    alloc: mem.Allocator,
    nodes: std.ArrayList(PathNode),
) !void {
    // Should not be called with zero nodes
    if (nodes.items.len == 0) return error.InvalidPathData;

    const scale: f64 = switch (self.context.anti_aliasing_mode) {
        .none => 1,
        .default => supersample_scale,
    };

    // NOTE: for now, we set a minimum thickness for the following options:
    // join_mode, miter_limit, and cap_mode. Any thickness lower than 2 will
    // cause these options to revert to the defaults of join_mode = .miter,
    // miter_limit = 10.0, cap_mode = .butt.
    //
    // This is a stop-gap to prevent artifacts with very thin lines (not
    // necessarily hairline, but close to being the single-pixel width that are
    // used to represent hairlines). As our path builder gets better for
    // stroking, I'm expecting that some of these restrictions will be lifted
    // and/or moved to specific places where they can be used to address the
    // artifacts related to particular edge cases.
    var plotter = try StrokePlotter.init(
        alloc,
        self.context.line_width,
        if (self.context.line_width >= 2) self.context.line_join_mode else .miter,
        if (self.context.line_width >= 2) self.context.miter_limit else 10.0,
        if (self.context.line_width >= 2) self.context.line_cap_mode else .butt,
        scale,
    );
    defer plotter.deinit();

    var polygons = try plotter.plot(alloc, nodes);
    defer polygons.deinit();

    switch (self.context.anti_aliasing_mode) {
        .none => {
            try self.paintDirect(alloc, polygons, .non_zero);
        },
        .default => {
            try self.paintComposite(alloc, polygons, .non_zero, scale);
        },
    }
}

/// Direct paint, writes to surface directly, avoiding compositing. Does not
/// use AA.
fn paintDirect(
    self: *const Painter,
    alloc: mem.Allocator,
    polygons: PolygonList,
    fill_rule: FillRule,
) !void {
    var arena = heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const poly_start_y: i32 = math.clamp(
        @as(i32, @intFromFloat(polygons.start.y)),
        0,
        self.context.surface.getHeight() - 1,
    );
    const poly_end_y: i32 = math.clamp(
        @as(i32, @intFromFloat(polygons.end.y)),
        0,
        self.context.surface.getHeight() - 1,
    );
    var y = poly_start_y;
    while (y <= poly_end_y) : (y += 1) {
        var edge_list = try polygons.edgesForY(arena_alloc, @floatFromInt(y), fill_rule);
        defer edge_list.deinit();

        var start_idx: usize = 0;
        while (start_idx + 1 < edge_list.items.len) : (start_idx += 2) {
            const start_x = math.clamp(
                edge_list.items[start_idx],
                0,
                self.context.surface.getWidth() - 1,
            );
            // Subtract 1 from the end edge as this is our pixel boundary
            // (end_x = 100 actually means we should only fill to x=99).
            const end_x = math.clamp(
                edge_list.items[start_idx + 1] - 1,
                0,
                self.context.surface.getWidth() - 1,
            );

            var x = start_x;
            while (x <= end_x) : (x += 1) {
                const src = try self.context.pattern.getPixel(x, y);
                const dst = try self.context.surface.getPixel(x, y);
                try self.context.surface.putPixel(x, y, dst.srcOver(src));
            }
        }
    }
}

/// Composite paint, for AA and other operations such as gradients (not yet
/// implemented).
fn paintComposite(
    self: *const Painter,
    alloc: mem.Allocator,
    polygons: PolygonList,
    fill_rule: FillRule,
    scale: f64,
) !void {
    var arena = heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const mask_sfc = sfc_m: {
        const offset_x: i32 = @intFromFloat(polygons.start.x);
        const offset_y: i32 = @intFromFloat(polygons.start.y);
        // Add scale to our relative dimensions here, as our polygon extent
        // figures stop at the end pixel, instead of what would technically be
        // one over. Using scale instead of 1 here ensures that we downscale
        // evenly to our original extent dimensions.
        const mask_width: i32 = @intFromFloat(polygons.end.x - polygons.start.x + scale);
        const mask_height: i32 = @intFromFloat(polygons.end.y - polygons.start.y + scale);
        const surface_width: i32 = self.context.surface.getWidth() * @as(i32, @intFromFloat(scale));

        const scaled_sfc = try Surface.init(
            .image_surface_alpha8,
            arena_alloc,
            mask_width,
            mask_height,
        );
        defer scaled_sfc.deinit();

        const poly_start_y: i32 = @intFromFloat(polygons.start.y);
        const poly_end_y: i32 = @intFromFloat(polygons.end.y);
        var y = poly_start_y;
        while (y <= poly_end_y) : (y += 1) {
            var edge_list = try polygons.edgesForY(arena_alloc, @floatFromInt(y), fill_rule);
            defer edge_list.deinit();

            var start_idx: usize = 0;
            while (start_idx + 1 < edge_list.items.len) {
                const start_x = @min(
                    surface_width,
                    edge_list.items[start_idx],
                );
                // Subtract 1 from the end edge as this is our pixel boundary
                // (end_x = 100 actually means we should only fill to x=99).
                const end_x = @min(
                    surface_width,
                    edge_list.items[start_idx + 1] - 1,
                );

                var x = start_x;
                while (x <= end_x) : (x += 1) {
                    try scaled_sfc.putPixel(
                        @intCast(x - offset_x),
                        @intCast(y - offset_y),
                        .{ .alpha8 = .{ .a = 255 } },
                    );
                }

                start_idx += 2;
            }
        }

        break :sfc_m try scaled_sfc.downsample();
    };
    defer mask_sfc.deinit();

    // Downscaled offsets
    const offset_x: i32 = @intFromFloat(polygons.start.x / scale);
    const offset_y: i32 = @intFromFloat(polygons.start.y / scale);
    // Add a 1 to our relative dimensions here, as our polygon extent figures
    // stop at the end pixel, instead of what would technically be one over.
    const width: i32 = @intFromFloat(polygons.end.x / scale - polygons.start.x / scale + 1);
    const height: i32 = @intFromFloat(polygons.end.y / scale - polygons.start.y / scale + 1);

    const foreground_sfc = switch (self.context.pattern) {
        // This is the surface that we composite our mask on to get the final
        // image that in turn gets composited to the main surface. To support
        // proper compositing of the mask, and in turn onto the main surface,
        // we use RGBA with our source copied over top.
        //
        // NOTE: This is just scaffolding for now, the only pattern we have
        // currently is the opaque single-pixel pattern, which is fast-pathed
        // below. Once we support things like gradients and what not, we will
        // expand this a bit more (e.g., initializing the surface with the
        // painted gradient).
        .opaque_pattern => try Surface.initPixel(
            RGBA.copySrc(try self.context.pattern.getPixel(1, 1)).asPixel(),
            arena_alloc,
            width,
            height,
        ),
    };
    defer foreground_sfc.deinit();
    try foreground_sfc.dstIn(mask_sfc, 0, 0); // Image fully rendered here
    try self.context.surface.srcOver(
        foreground_sfc,
        offset_x,
        offset_y,
    ); // Final compositing to main surface
}
