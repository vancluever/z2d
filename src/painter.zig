// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024 Chris Marchesi

//! Contains unmanaged painter functions for filling and stroking.

const std = @import("std");
const debug = @import("std").debug;
const heap = @import("std").heap;
const math = @import("std").math;
const mem = @import("std").mem;
const testing = @import("std").testing;

const fill_plotter = @import("internal/FillPlotter.zig");
const options = @import("options.zig");

const Context = @import("Context.zig");
const Path = @import("Path.zig");
const PathNode = @import("internal/path_nodes.zig").PathNode;
const RGBA = @import("pixel.zig").RGBA;
const Surface = @import("surface.zig").Surface;
const Pattern = @import("pattern.zig").Pattern;
const FillRule = @import("options.zig").FillRule;
const StrokePlotter = @import("internal/StrokePlotter.zig");
const Polygon = @import("internal/Polygon.zig");
const PolygonList = @import("internal/PolygonList.zig");
const Transformation = @import("Transformation.zig");
const InternalError = @import("internal/InternalError.zig").InternalError;
const supersample_scale = @import("surface.zig").supersample_scale;

pub const FillOpts = struct {
    /// The anti-aliasing mode to use with the fill operation.
    anti_aliasing_mode: options.AntiAliasMode = .default,

    /// The fill rule to use during the fill operation.
    fill_rule: options.FillRule = .non_zero,

    /// The maximum error tolerance used for approximating curves and arcs. A
    /// higher tolerance will give better performance, but "blockier" curves.
    /// The default tolerance should be sufficient for most cases.
    tolerance: f64 = options.default_tolerance,
};

/// Errors related to the `fill` operation.
pub const FillError = error{
    /// The supplied path (and any sub-paths) have not been explicitly closed,
    /// which is required by the fill operation.
    PathNotClosed,
} || Surface.Error || InternalError || mem.Allocator.Error;

/// Runs a fill operation on the path set represented by `nodes`.
pub fn fill(
    alloc: mem.Allocator,
    surface: *Surface,
    pattern: *const Pattern,
    nodes: []const PathNode,
    opts: FillOpts,
) FillError!void {
    if (nodes.len == 0) return;
    if (!PathNode.isClosedNodeSet(nodes)) return error.PathNotClosed;

    const scale: f64 = switch (opts.anti_aliasing_mode) {
        .none => 1,
        .default => supersample_scale,
    };

    var polygons = try fill_plotter.plot(
        alloc,
        nodes,
        scale,
        @max(opts.tolerance, 0.001),
    );
    defer polygons.deinit();

    switch (opts.anti_aliasing_mode) {
        .none => {
            try paintDirect(alloc, surface, pattern, polygons, opts.fill_rule);
        },
        .default => {
            try paintComposite(alloc, surface, pattern, polygons, opts.fill_rule, scale);
        },
    }
}

pub const StrokeOpts = struct {
    /// The anti-aliasing mode to use with the stroke operation.
    anti_aliasing_mode: options.AntiAliasMode = .default,

    /// The line cap rule for the stroke operation.
    line_cap_mode: options.CapMode = .butt,

    /// The line join style for the stroke operation.
    line_join_mode: options.JoinMode = .miter,

    /// The line width for the stroke operation.
    line_width: f64 = 2.0,

    /// The maximum allowed ratio for miter joins. See `Context` for a full
    /// explanation of this setting.
    miter_limit: f64 = 10.0,

    /// The maximum error tolerance used for approximating curves and arcs. A
    /// higher tolerance will give better performance, but "blockier" curves.
    /// The default tolerance should be sufficient for most cases.
    tolerance: f64 = options.default_tolerance,

    /// The transformation matrix to use for the stroke operation. Has more
    /// subtle influences on drawing, affecting line width respective to scale,
    /// warping due to a warped scale (e.g., different x and y scale), and any
    /// respective capping.
    transformation: Transformation = Transformation.identity,
};

/// Errors related to the `stroke` operation.
pub const StrokeError = Transformation.Error || Surface.Error || InternalError || mem.Allocator.Error;

/// Runs a stroke operation on the path set represented by `nodes`. The path(s)
/// is/are transformed to one or more polygon(s) representing the line(s),
/// which are then filled.
pub fn stroke(
    alloc: mem.Allocator,
    surface: *Surface,
    pattern: *const Pattern,
    nodes: []const PathNode,
    opts: StrokeOpts,
) StrokeError!void {
    // Attempt to inverse the matrix supplied to ensure it can be inverted
    // farther down.
    _ = try opts.transformation.inverse();

    // Return if called with zero nodes.
    if (nodes.len == 0) return;

    const scale: f64 = switch (opts.anti_aliasing_mode) {
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
    //
    // Not a stop gap more than likely: minimum line width. This is value is
    // sort of arbitrarily chosen as Cairo's minimum 24.8 fixed-point value (so
    // 1/256).
    const minimum_line_width: f64 = 0.00390625;
    var plotter = try StrokePlotter.init(
        alloc,
        if (opts.line_width >= minimum_line_width) opts.line_width else minimum_line_width,
        if (opts.line_width >= 2) opts.line_join_mode else .miter,
        if (opts.line_width >= 2) opts.miter_limit else 10.0,
        if (opts.line_width >= 2) opts.line_cap_mode else .butt,
        scale,
        @max(opts.tolerance, 0.001),
        opts.transformation,
    );
    defer plotter.deinit();

    var polygons = try plotter.plot(alloc, nodes);
    defer polygons.deinit();

    switch (opts.anti_aliasing_mode) {
        .none => {
            try paintDirect(alloc, surface, pattern, polygons, .non_zero);
        },
        .default => {
            try paintComposite(alloc, surface, pattern, polygons, .non_zero, scale);
        },
    }
}

const PaintError = Surface.Error || InternalError || mem.Allocator.Error;

/// Direct paint, writes to surface directly, avoiding compositing. Does not
/// use AA.
fn paintDirect(
    alloc: mem.Allocator,
    surface: *Surface,
    pattern: *const Pattern,
    polygons: PolygonList,
    fill_rule: FillRule,
) PaintError!void {
    const poly_start_y: i32 = math.clamp(
        @as(i32, @intFromFloat(@floor(polygons.start.y))),
        0,
        surface.getHeight() - 1,
    );
    const poly_end_y: i32 = math.clamp(
        @as(i32, @intFromFloat(@ceil(polygons.end.y))),
        0,
        surface.getHeight() - 1,
    );
    var y = poly_start_y;
    while (y <= poly_end_y) : (y += 1) {
        // Make a small FBA for edge caches, falling back to the passed in
        // allocator if we need to. This should be more than enough to do most
        // cases, but we can't guarantee it and we don't necessarily want to
        // blow up the stack.
        var edge_stack_fallback = heap.stackFallback(512, alloc);
        const edge_alloc = edge_stack_fallback.get();
        var edge_list = try polygons.edgesForY(edge_alloc, @floatFromInt(y), fill_rule);
        defer edge_list.deinit(edge_alloc);
        while (edge_list.next()) |edge_pair| {
            const start_x = math.clamp(
                edge_pair.start,
                0,
                surface.getWidth() - 1,
            );
            // Subtract 1 from the end edge as this is our pixel boundary
            // (end_x = 100 actually means we should only fill to x=99).
            const end_x = math.clamp(
                edge_pair.end - 1,
                0,
                surface.getWidth() - 1,
            );

            var x = start_x;
            while (x <= end_x) : (x += 1) {
                const src = pattern.getPixel(x, y);
                const dst = surface.getPixel(x, y) orelse unreachable;
                surface.putPixel(x, y, dst.srcOver(src));
            }
        }
    }
}

/// Composite paint, for AA and other operations such as gradients (not yet
/// implemented).
fn paintComposite(
    alloc: mem.Allocator,
    surface: *Surface,
    pattern: *const Pattern,
    polygons: PolygonList,
    fill_rule: FillRule,
    scale: f64,
) PaintError!void {
    // This math expects integer scaling.
    debug.assert(@floor(scale) == scale);
    const i_scale: i32 = @intFromFloat(scale);

    // This is the area on the original image which our polygons may touch.
    // This range is *exclusive* of the right (max) end, hence why we add 1
    // to the maximum coordinates.
    const x0: i32 = @intFromFloat(@floor(polygons.start.x / scale));
    const y0: i32 = @intFromFloat(@floor(polygons.start.y / scale));
    const x1: i32 = @intFromFloat(@floor(polygons.end.x / scale) + 1);
    const y1: i32 = @intFromFloat(@floor(polygons.end.y / scale) + 1);

    var mask_sfc = sfc_m: {
        // We calculate a scaled up version of the
        // extents for our supersampled drawing.
        const box_x0: i32 = x0 * i_scale;
        const box_y0: i32 = y0 * i_scale;
        const box_x1: i32 = x1 * i_scale;
        const box_y1: i32 = y1 * i_scale;
        const mask_width: i32 = box_x1 - box_x0;
        const mask_height: i32 = box_y1 - box_y0;
        const offset_x: i32 = box_x0;
        const offset_y: i32 = box_y0;

        var scaled_sfc = try Surface.init(
            .image_surface_alpha8,
            alloc,
            mask_width,
            mask_height,
        );
        errdefer scaled_sfc.deinit(alloc);

        const poly_y0: i32 = box_y0;
        const poly_y1: i32 = box_y1;
        var y = poly_y0;
        while (y < poly_y1) : (y += 1) {
            // Make a small FBA for edge caches, falling back to the passed in
            // allocator if we need to. This should be more than enough to do
            // most cases, but we can't guarantee it and we don't necessarily
            // want to blow up the stack.
            var edge_stack_fallback = heap.stackFallback(512, alloc);
            const edge_alloc = edge_stack_fallback.get();
            var edge_list = try polygons.edgesForY(edge_alloc, @floatFromInt(y), fill_rule);
            defer edge_list.deinit(edge_alloc);
            while (edge_list.next()) |edge_pair| {
                const start_x = edge_pair.start;
                const end_x = edge_pair.end;

                var x = start_x;
                // We fill up to, but not including, the end point.
                while (x < end_x) : (x += 1) {
                    scaled_sfc.putPixel(
                        @intCast(x - offset_x),
                        @intCast(y - offset_y),
                        .{ .alpha8 = .{ .a = 255 } },
                    );
                }
            }
        }

        scaled_sfc.downsample(alloc);
        break :sfc_m scaled_sfc;
    };
    defer mask_sfc.deinit(alloc);

    // Surface.deinit is not currently idempotent. Given that this is the only
    // place where we might double-call deinit at this point, we can just track
    // whether or not we need the extra de-init here, versus update the
    // interface unnecessarily.
    var deinit_fg = false;
    var foreground_sfc = sfc_f: {
        switch (pattern.*) {
            // This is the surface that we composite our mask on to get the
            // final image that in turn gets composited to the main surface. To
            // support proper compositing of the mask, and in turn onto the
            // main surface, we use RGBA with our source copied over top (other
            // than covered alpha8 special cases below).
            //
            // NOTE: This is just scaffolding for now, the only pattern we have
            // currently is the opaque single-pixel pattern, which is fast-pathed
            // below. Once we support things like gradients and what not, we will
            // expand this a bit more (e.g., initializing the surface with the
            // painted gradient).
            .opaque_pattern => {
                const px = pattern.getPixel(0, 0);
                if (px == .alpha8) {
                    // Our source pixel is alpha8, so we can avoid a
                    // pretty costly allocation here by just using our
                    // mask as the foreground. We just need to check if
                    // we need to do any composition (depending on
                    // whether or not our source is a full opaque
                    // alpha).
                    if (px.alpha8.a != 255) {
                        const pxa = px.alpha8;
                        for (mask_sfc.image_surface_alpha8.buf, 0..) |sfc_px, i| {
                            mask_sfc.image_surface_alpha8.buf[i] = pxa.dstIn(sfc_px.asPixel());
                        }
                    }
                    break :sfc_f mask_sfc;
                }

                var fg_sfc = try Surface.initPixel(
                    RGBA.copySrc(pattern.getPixel(0, 0)).asPixel(),
                    alloc,
                    mask_sfc.getWidth(),
                    mask_sfc.getHeight(),
                );
                errdefer fg_sfc.deinit(alloc);

                // Image fully rendered here
                fg_sfc.dstIn(&mask_sfc, 0, 0);
                deinit_fg = true; // Mark foreground for deinit when done
                break :sfc_f fg_sfc;
            },
        }
    };
    defer {
        if (deinit_fg) foreground_sfc.deinit(alloc);
    }

    // Final compositing to main surface
    surface.srcOver(&foreground_sfc, x0, y0);
}

test "stroke uninvertible matrix error" {
    var sfc = try Surface.init(.image_surface_rgb, testing.allocator, 1, 1);
    defer sfc.deinit(testing.allocator);
    try testing.expectError(Transformation.Error.InvalidMatrix, stroke(
        testing.allocator,
        &sfc,
        &.{
            .opaque_pattern = .{
                .pixel = .{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } }, // White on black
            },
        },
        &.{},
        .{ .transformation = .{
            .ax = 1,
            .by = 1,
            .cx = 2,
            .dy = 2,
            .tx = 5,
            .ty = 6,
        } },
    ));
}
