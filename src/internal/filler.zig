const std = @import("std");
const debug = @import("std").debug;
const heap = @import("std").heap;
const mem = @import("std").mem;

const nodepkg = @import("nodes.zig");
const patternpkg = @import("../pattern.zig");
const pixelpkg = @import("../pixel.zig");
const polypkg = @import("polygon.zig");
const surfacepkg = @import("../surface.zig");
const spline = @import("spline_transformer.zig");
const units = @import("../units.zig");
const options = @import("../options.zig");

/// Runs a fill operation on this current path and any subpaths.
pub fn fill(
    alloc: mem.Allocator,
    nodes: std.ArrayList(nodepkg.PathNode),
    surface: surfacepkg.Surface,
    pattern: patternpkg.Pattern,
    anti_aliasing_mode: options.AntiAliasMode,
    fill_rule: options.FillRule,
) !void {
    // There should be a minimum of two nodes in anything passed here.
    // Additionally, the higher-level path API also always adds an explicit
    // move_to after close_path nodes, so we assert on this.
    //
    // NOTE: obviously, to be useful, there would be much more than two nodes,
    // but this is just the minimum for us to assert that the path has been
    // closed correctly.
    debug.assert(nodes.items.len >= 2);
    debug.assert(nodes.items[nodes.items.len - 2] == .close_path);
    debug.assert(nodes.getLast() == .move_to);

    switch (anti_aliasing_mode) {
        .none => {
            try paintDirect(alloc, nodes, surface, pattern, fill_rule);
        },
        .default => {
            try paintComposite(alloc, nodes, surface, pattern, fill_rule);
        },
    }
}

/// Direct paint, writes to surface directly, avoiding compositing. Does not
/// use AA.
fn paintDirect(
    alloc: mem.Allocator,
    nodes: std.ArrayList(nodepkg.PathNode),
    surface: surfacepkg.Surface,
    pattern: patternpkg.Pattern,
    fill_rule: options.FillRule,
) !void {
    var polygon_list = try plot(alloc, nodes, 1);
    defer polygon_list.deinit();
    const poly_start_y: usize = @intFromFloat(polygon_list.start.y);
    const poly_end_y: usize = @intFromFloat(polygon_list.end.y);
    for (poly_start_y..poly_end_y + 1) |y| {
        var edge_list = try polygon_list.edgesForY(@floatFromInt(y), fill_rule);
        defer edge_list.deinit();

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

            for (start_x..end_x) |x| {
                // TODO: Add pixel-by-pixel compositing to this (src-over).
                // This comes at a cost of course, but will be correct for the
                // expectations of paint operations when working with the alpha
                // channel.
                const src = try pattern.getPixel(@intCast(x), @intCast(y));
                const dst = try surface.getPixel(@intCast(x), @intCast(y));
                try surface.putPixel(@intCast(x), @intCast(y), dst.srcOver(src));
            }

            start_idx += 2;
        }
    }
}

/// Composite paint, for AA and other operations such as gradients (not yet
/// implemented).
fn paintComposite(
    alloc: mem.Allocator,
    nodes: std.ArrayList(nodepkg.PathNode),
    surface: surfacepkg.Surface,
    pattern: patternpkg.Pattern,
    fill_rule: options.FillRule,
) !void {
    var arena = heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const scale: f64 = surfacepkg.supersample_scale;
    var polygon_list = try plot(arena_alloc, nodes, scale);
    defer polygon_list.deinit();

    const mask_sfc = sfc_m: {
        const offset_x: u32 = @intFromFloat(polygon_list.start.x);
        const offset_y: u32 = @intFromFloat(polygon_list.start.y);
        // Add scale to our relative dimensions here, as our polygon extent
        // figures stop at the end pixel, instead of what would technically be
        // one over. Using scale instead of 1 here ensures that we downscale
        // evenly to our original extent dimensions.
        const mask_width: u32 = @intFromFloat(polygon_list.end.x - polygon_list.start.x + scale);
        const mask_height: u32 = @intFromFloat(polygon_list.end.y - polygon_list.start.y + scale);
        const surface_width: u32 = surface.getWidth() * @as(u32, @intFromFloat(scale));

        const scaled_sfc = try surfacepkg.Surface.init(
            .image_surface_alpha8,
            arena_alloc,
            mask_width,
            mask_height,
        );
        defer scaled_sfc.deinit();

        const poly_start_y: usize = @intFromFloat(polygon_list.start.y);
        const poly_end_y: usize = @intFromFloat(polygon_list.end.y);
        for (poly_start_y..poly_end_y + 1) |y| {
            var edge_list = try polygon_list.edgesForY(@floatFromInt(y), fill_rule);
            defer edge_list.deinit();

            var start_idx: usize = 0;
            while (start_idx + 1 < edge_list.items.len) {
                const start_x = @min(
                    surface_width,
                    edge_list.items[start_idx],
                );
                const end_x = @min(
                    surface_width,
                    edge_list.items[start_idx + 1],
                );

                for (start_x..end_x) |x| {
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
    const offset_x: u32 = @intFromFloat(polygon_list.start.x / scale);
    const offset_y: u32 = @intFromFloat(polygon_list.start.y / scale);
    // Add a 1 to our relative dimensions here, as our polygon extent figures
    // stop at the end pixel, instead of what would technically be one over.
    const width: u32 = @intFromFloat(polygon_list.end.x / scale - polygon_list.start.x / scale + 1);
    const height: u32 = @intFromFloat(polygon_list.end.y / scale - polygon_list.start.y / scale + 1);

    const foreground_sfc = switch (pattern) {
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
        .opaque_pattern => try surfacepkg.Surface.initPixel(
            pixelpkg.RGBA.copySrc(try pattern.getPixel(1, 1)).asPixel(),
            arena_alloc,
            width,
            height,
        ),
    };
    defer foreground_sfc.deinit();
    try foreground_sfc.dstIn(mask_sfc, 0, 0); // Image fully rendered here
    try surface.srcOver(foreground_sfc, offset_x, offset_y); // Final compositing to main surface
}

/// parses the node list and plots the points therein, and returns a polygon
/// list suitable for filling.
///
/// The caller owns the polygon list and needs to call deinit on it.
fn plot(alloc: mem.Allocator, nodes: std.ArrayList(nodepkg.PathNode), scale: f64) !polypkg.PolygonList {
    var polygon_list = polypkg.PolygonList.init(alloc, scale);
    errdefer polygon_list.deinit();

    var initial_point: ?units.Point = null;
    var current_point: ?units.Point = null;

    for (nodes.items, 0..) |node, i| {
        switch (node) {
            .move_to => |n| {
                // Check if this is the last node, and no-op if it is, as this
                // is the auto-added move_to node that is given after
                // close_path.
                if (i == nodes.items.len - 1) {
                    break;
                }

                try polygon_list.beginNew();
                try polygon_list.plot(n.point);
                initial_point = n.point;
                current_point = n.point;
            },
            .line_to => |n| {
                debug.assert(initial_point != null);
                debug.assert(current_point != null);

                try polygon_list.plot(n.point);
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
                        .line_to => |tnn| try polygon_list.plot(tnn.point),
                        else => unreachable, // spline transformer does not return anything else
                    }
                }
            },
            .close_path => {
                debug.assert(initial_point != null);
                debug.assert(current_point != null);

                // No-op if our initial and current points are equal
                if (current_point.?.equal(initial_point.?)) break;

                // Set the current point to the initial point.
                current_point = initial_point;
            },
        }
    }

    return polygon_list;
}
