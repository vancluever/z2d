// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024-2025 Chris Marchesi

//! Contains unmanaged painter functions for filling and stroking.

const std = @import("std");
const debug = @import("std").debug;
const heap = @import("std").heap;
const math = @import("std").math;
const mem = @import("std").mem;
const testing = @import("std").testing;

const fill_plotter = @import("internal/fill_plotter.zig");
const stroke_plotter = @import("internal/stroke_plotter.zig");
const options = @import("options.zig");
const pixel = @import("pixel.zig");

const Context = @import("Context.zig");
const Path = @import("Path.zig");
const PathNode = @import("internal/path_nodes.zig").PathNode;
const SparseCoverageBuffer = @import("internal/sparse_coverage.zig").SparseCoverageBuffer;
const Surface = @import("surface.zig").Surface;
const SurfaceType = @import("surface.zig").SurfaceType;
const Pattern = @import("pattern.zig").Pattern;
const FillRule = @import("options.zig").FillRule;
const Polygon = @import("internal/Polygon.zig");
const Transformation = @import("Transformation.zig");
const InternalError = @import("internal/InternalError.zig").InternalError;
const supersample_scale = @import("surface.zig").supersample_scale;
const compositor = @import("compositor.zig");

pub const FillOpts = struct {
    /// The anti-aliasing mode to use with the fill operation.
    anti_aliasing_mode: options.AntiAliasMode = .default,

    /// The fill rule to use during the fill operation.
    fill_rule: options.FillRule = .non_zero,

    /// The operator to use for compositing.
    operator: compositor.Operator = .src_over,

    /// The precision to use when compositing.
    precision: compositor.Precision = .integer,

    /// The maximum error tolerance used for approximating curves and arcs. A
    /// higher tolerance will give better performance, but "blockier" curves.
    /// The default tolerance should be sufficient for most cases.
    tolerance: f64 = options.default_tolerance,
};

/// Errors related to the `fill` operation.
///
/// **Note for autodoc viewers:** `std.mem.Allocator.Error` is a member of this
/// set, but is not shown because `std` is pruned from our autodoc.
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

    // Force AA mode to .none if we are using an 1-bit alpha layer; there's no
    // point in using AA in this mode as pixels are either on or off, and no
    // in-between. This optimizes this path fully, saves RAM and processing
    // time.
    const aa_mode: options.AntiAliasMode = if (surface.* == .image_surface_alpha1)
        .none
    else
        opts.anti_aliasing_mode;

    const scale: f64 = switch (aa_mode) {
        .none => 1,
        .supersample_4x => supersample_scale,
        .default, .multisample_4x => SparseCoverageBuffer.scale,
    };

    var polygons = try fill_plotter.plot(
        alloc,
        nodes,
        scale,
        @max(opts.tolerance, 0.001),
    );
    defer polygons.deinit(alloc);

    switch (aa_mode) {
        .none => {
            try paintDirect(
                alloc,
                surface,
                pattern,
                polygons,
                opts.fill_rule,
                opts.operator,
                opts.precision,
            );
        },
        .supersample_4x => {
            try paintSuperSample(
                alloc,
                surface,
                pattern,
                polygons,
                opts.fill_rule,
                scale,
                opts.operator,
                opts.precision,
            );
        },
        .default, .multisample_4x => {
            try paintMultiSample(
                alloc,
                surface,
                pattern,
                polygons,
                opts.fill_rule,
                opts.operator,
                opts.precision,
            );
        },
    }
}

pub const StrokeOpts = struct {
    /// The anti-aliasing mode to use with the stroke operation.
    anti_aliasing_mode: options.AntiAliasMode = .default,

    /// The dash array, if dashed lines are desired. See `Context` for a full
    /// explanation of this setting.
    dashes: []const f64 = &.{},

    /// The dash offset when doing dashed lines. See `Context` for a full
    /// explanation of this setting.
    dash_offset: f64 = 0,

    /// The line cap rule for the stroke operation.
    line_cap_mode: options.CapMode = .butt,

    /// The line join style for the stroke operation.
    line_join_mode: options.JoinMode = .miter,

    /// The line width for the stroke operation.
    line_width: f64 = 2.0,

    /// The maximum allowed ratio for miter joins. See `Context` for a full
    /// explanation of this setting.
    miter_limit: f64 = 10.0,

    /// The operator to use for compositing.
    operator: compositor.Operator = .src_over,

    /// The precision to use when compositing.
    precision: compositor.Precision = .integer,

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
///
/// **Note for autodoc viewers:** `std.mem.Allocator.Error` is a member of this
/// set, but is not shown because `std` is pruned from our autodoc.
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

    // Force AA mode to .none if we are using an 1-bit alpha layer; there's no
    // point in using AA in this mode as pixels are either on or off, and no
    // in-between. This optimizes this path fully, saves RAM and processing
    // time.
    const aa_mode: options.AntiAliasMode = if (surface.* == .image_surface_alpha1)
        .none
    else
        opts.anti_aliasing_mode;

    const scale: f64 = switch (aa_mode) {
        .none => 1,
        .supersample_4x => supersample_scale,
        .default, .multisample_4x => SparseCoverageBuffer.scale,
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
    var polygons = try stroke_plotter.plot(
        alloc,
        nodes,
        .{
            .cap_mode = if (opts.line_width >= 2) opts.line_cap_mode else .butt,
            .ctm = opts.transformation,
            .dashes = opts.dashes,
            .dash_offset = opts.dash_offset,
            .join_mode = if (opts.line_width >= 2) opts.line_join_mode else .miter,
            .miter_limit = if (opts.line_width >= 2) opts.miter_limit else 10.0,
            .scale = scale,
            .thickness = if (opts.line_width >= minimum_line_width)
                opts.line_width
            else
                minimum_line_width,
            .tolerance = @max(opts.tolerance, 0.001),
        },
    );
    defer polygons.deinit(alloc);

    switch (aa_mode) {
        .none => {
            try paintDirect(
                alloc,
                surface,
                pattern,
                polygons,
                .non_zero,
                opts.operator,
                opts.precision,
            );
        },
        .supersample_4x => {
            try paintSuperSample(
                alloc,
                surface,
                pattern,
                polygons,
                .non_zero,
                scale,
                opts.operator,
                opts.precision,
            );
        },
        .default, .multisample_4x => {
            try paintMultiSample(
                alloc,
                surface,
                pattern,
                polygons,
                .non_zero,
                opts.operator,
                opts.precision,
            );
        },
    }
}

const PaintError = Surface.Error || InternalError || mem.Allocator.Error;

fn paintDirect(
    alloc: mem.Allocator,
    surface: *Surface,
    pattern: *const Pattern,
    polygons: Polygon,
    fill_rule: FillRule,
    operator: compositor.Operator,
    precision: compositor.Precision,
) PaintError!void {
    const sfc_width: i32 = surface.getWidth();
    const sfc_height: i32 = surface.getHeight();
    const _precision = if (operator.requiresFloat()) .float else precision;
    const bounded = operator.isBounded();

    // Do an initial check to see if our polygon is within the surface, if it
    // isn't, it's a no-op.
    //
    // This also enforces positive and non-zero surface dimensions, and
    // correctly defined polygon extents (e.g., that the end extents are
    // greater than the start extents).
    if (!polygons.inBox(1.0, sfc_width, sfc_height)) {
        return;
    }

    // This is the scanline range on the original image which our polygons may
    // touch (in the event our operator is bounded, otherwise it's the whole of
    // the surface).
    //
    // This range has to accommodate the extents of the top and bottom of the
    // polygon rectangle, so it needs to be "pushed out"; floored on the top,
    // and ceilinged on the bottom.
    const poly_start_y: i32 = if (bounded) @intFromFloat(@floor(polygons.extent_top)) else 0;
    const poly_end_y: i32 = if (bounded) @intFromFloat(@ceil(polygons.extent_bottom)) else sfc_height - 1;
    // Clamp the scanlines to the surface
    const start_scanline: i32 = math.clamp(poly_start_y, 0, sfc_height - 1);
    const end_scanline: i32 = math.clamp(poly_end_y, start_scanline, sfc_height - 1);

    // Make an ArenaAllocator for our edges, this allows us to re-use the same
    // memory after every scanline by simply resetting the arena.
    var edge_arena = heap.ArenaAllocator.init(alloc);
    defer edge_arena.deinit();
    const edge_alloc = edge_arena.allocator();

    // Note that we have to add 1 to the end scanline here as our start -> end
    // boundaries above only account for+clamp to the last line to be scanned,
    // so our len is end + 1. This helps correct for scenarios like small
    // polygons laying on edges, or very small surfaces (e.g., 1 pixel high).
    for (@max(0, start_scanline)..@max(0, end_scanline) + 1) |y_u| {
        defer {
            _ = edge_arena.reset(.retain_capacity);
        }
        const y: i32 = @intCast(y_u);

        var edge_list = try polygons.xEdgesForY(edge_alloc, @floatFromInt(y), fill_rule);
        defer edge_list.deinit(edge_alloc);

        if (!bounded and edge_list.items.len == 0) {
            // Empty line but we're not bounded, so we clear the whole line.
            const clear_stride = surface.getStride(0, y, @max(0, sfc_width));
            compositor.StrideCompositor.run(clear_stride, &.{.{
                .operator = .clear,
                .src = .{ .pixel = .{ .rgba = .{ .r = 0, .g = 0, .b = 0, .a = 0 } } },
            }}, .{ .precision = .integer });

            continue;
        }

        for (0..edge_list.items.len / 2) |edge_pair_idx| {
            const edge_pair_start = edge_pair_idx * 2;
            const start_x: i32 = math.clamp(
                edge_list.items[edge_pair_start],
                0,
                sfc_width - 1,
            );
            const end_x: i32 = math.clamp(
                edge_list.items[edge_pair_start + 1],
                start_x,
                sfc_width,
            );
            const fill_len: i32 = end_x - start_x;
            const end_clear_len: i32 = sfc_width - end_x;

            if (!bounded and start_x > 0) {
                // Clear up to the start
                const clear_stride = surface.getStride(0, y, @max(0, start_x));
                compositor.StrideCompositor.run(clear_stride, &.{.{
                    .operator = .clear,
                    .src = .{ .pixel = .{ .rgba = .{ .r = 0, .g = 0, .b = 0, .a = 0 } } },
                }}, .{ .precision = .integer });
            }

            if (fill_len > 0) {
                const dst_stride = surface.getStride(start_x, y, @max(0, fill_len));
                compositor.StrideCompositor.run(dst_stride, &.{.{
                    .operator = operator,
                    .src = switch (pattern.*) {
                        .opaque_pattern => .{ .pixel = pattern.opaque_pattern.pixel },
                        .gradient => |g| .{ .gradient = .{
                            .underlying = g,
                            .x = start_x,
                            .y = y,
                        } },
                        .dither => .{ .dither = .{
                            .underlying = pattern.dither,
                            .x = start_x,
                            .y = y,
                        } },
                    },
                }}, .{ .precision = _precision });
            }

            if (!bounded and end_clear_len > 0) {
                // Clear to the end
                const clear_stride = surface.getStride(end_x, y, @max(0, end_clear_len));
                compositor.StrideCompositor.run(clear_stride, &.{.{
                    .operator = .clear,
                    .src = .{ .pixel = .{ .rgba = .{ .r = 0, .g = 0, .b = 0, .a = 0 } } },
                }}, .{ .precision = .integer });
            }
        }
    }
}

fn paintSuperSample(
    alloc: mem.Allocator,
    surface: *Surface,
    pattern: *const Pattern,
    polygons: Polygon,
    fill_rule: FillRule,
    scale: f64,
    operator: compositor.Operator,
    precision: compositor.Precision,
) PaintError!void {
    // Do an initial check to see if our polygon is within the surface, if it
    // isn't, it's a no-op.
    //
    // This also enforces positive and non-zero surface dimensions, and
    // correctly defined polygon extents (e.g., that the end extents are
    // greater than the start extents).
    if (!polygons.inBox(scale, surface.getWidth(), surface.getHeight())) {
        return;
    }

    // This math expects integer scaling.
    debug.assert(@floor(scale) == scale);
    const i_scale: i32 = @intFromFloat(scale);

    // This is the area on the original image which our polygons may touch (in
    // the event our operator is bounded, otherwise it's the whole of the
    // surface).
    //
    // This range has to accommodate the extents of any possible point in the
    // polygon rectangle, so it needs to be "pushed out"; floored on the
    // top/left, and ceilinged on the bottom/right.
    const bounded = operator.isBounded();
    const x0: i32 = if (bounded) @intFromFloat(@floor(polygons.extent_left / scale)) else 0;
    const y0: i32 = if (bounded) @intFromFloat(@floor(polygons.extent_top / scale)) else 0;
    const x1: i32 = if (bounded)
        @intFromFloat(@ceil(polygons.extent_right / scale))
    else
        surface.getWidth();
    const y1: i32 = if (bounded)
        @intFromFloat(@ceil(polygons.extent_bottom / scale))
    else
        surface.getHeight();

    var mask_sfc = sfc_m: {
        // We calculate a scaled up version of the
        // extents for our supersampled drawing.
        //
        // These dimensions are clamped to the target surface to avoid
        // edge cases and unnecessary work.
        const target_width_scaled: i32 = surface.getWidth() * i_scale;
        const target_height_scaled: i32 = surface.getHeight() * i_scale;
        const box_x0: i32 = math.clamp(x0 * i_scale, 0, target_width_scaled - 1);
        const box_y0: i32 = math.clamp(y0 * i_scale, 0, target_height_scaled - 1);
        const box_x1: i32 = math.clamp(x1 * i_scale, box_x0, target_width_scaled - 1);
        const box_y1: i32 = math.clamp(y1 * i_scale, box_y0, target_height_scaled - 1);
        const mask_width: i32 = (box_x1 + 1) - box_x0;
        const mask_height: i32 = (box_y1 + 1) - box_y0;

        if (mask_width < 1 or mask_height < 1) {
            // This should have been checked earlier, if we hit this, it's a bug.
            @panic("invalid mask dimensions. this is a bug, please report it");
        }

        // Check our surface type. If we are one of our < 8bpp alpha surfaces,
        // we use that type instead.
        const surface_type: SurfaceType = switch (surface.*) {
            .image_surface_alpha4, .image_surface_alpha2, .image_surface_alpha1 => surface.*,
            else => .image_surface_alpha8,
        };
        const opaque_px: pixel.Pixel = switch (surface_type) {
            .image_surface_alpha4 => pixel.Alpha4.Opaque.asPixel(),
            .image_surface_alpha2 => pixel.Alpha2.Opaque.asPixel(),
            .image_surface_alpha1 => pixel.Alpha1.Opaque.asPixel(),
            else => pixel.Alpha8.Opaque.asPixel(),
        };
        var mask_sfc_scaled = try Surface.init(
            surface_type,
            alloc,
            mask_width,
            mask_height,
        );
        errdefer mask_sfc_scaled.deinit(alloc);

        // Make an ArenaAllocator for our edges, this allows us to re-use the
        // same memory after every scanline by simply resetting the arena.
        var edge_arena = heap.ArenaAllocator.init(alloc);
        defer edge_arena.deinit();
        const edge_alloc = edge_arena.allocator();

        for (0..@max(0, mask_height)) |y_u| {
            defer {
                _ = edge_arena.reset(.retain_capacity);
            }
            const y: i32 = @intCast(y_u);

            // Our polygon co-ordinates are in (scaled) device space, so when
            // we search for edges, we need to offset our mask-space scanline
            // to that.
            var edge_list = try polygons.xEdgesForY(edge_alloc, @floatFromInt(y + box_y0), fill_rule);
            defer edge_list.deinit(edge_alloc);
            for (0..edge_list.items.len / 2) |edge_pair_idx| {
                // Inverse to the above; pull back our scaled device space
                // co-ordinates to mask space.
                const edge_pair_start = edge_pair_idx * 2;
                const start_x: i32 =
                    math.clamp(edge_list.items[edge_pair_start] - box_x0, 0, mask_width - 1);
                const end_x: i32 =
                    math.clamp(edge_list.items[edge_pair_start + 1] - box_x0, start_x, mask_width);

                const fill_len: i32 = end_x - start_x;
                if (fill_len > 0) {
                    mask_sfc_scaled.paintStride(start_x, y, @max(0, fill_len), opaque_px);
                }
            }
        }

        mask_sfc_scaled.downsample(alloc);
        break :sfc_m mask_sfc_scaled;
    };
    defer mask_sfc.deinit(alloc);

    // We only bother clamping here on the low end since we've clipped
    // upper-left overlaps at (0,0). Offsets out of bounds of the surface
    // should have been filtered by the polygon/surface check at the start of
    // the function (and the compositor will ignore out-of-surface offsets
    // too).
    const comp_x: i32 = @max(0, x0);
    const comp_y: i32 = @max(0, y0);
    compositor.SurfaceCompositor.run(surface, comp_x, comp_y, 2, .{
        .{
            .operator = .dst_in,
            .dst = switch (pattern.*) {
                .opaque_pattern => .{ .pixel = pattern.opaque_pattern.pixel },
                .gradient => .{ .gradient = pattern.gradient },
                .dither => .{ .dither = pattern.dither },
            },
            .src = .{ .surface = &mask_sfc },
        },
        .{
            .operator = operator,
        },
    }, .{ .precision = precision });
}

fn paintMultiSample(
    alloc: mem.Allocator,
    surface: *Surface,
    pattern: *const Pattern,
    polygons: Polygon,
    fill_rule: FillRule,
    operator: compositor.Operator,
    precision: compositor.Precision,
) PaintError!void {
    const scale = SparseCoverageBuffer.scale;
    const coverage_full = scale * scale;
    const alpha_scale: i32 = 256 / coverage_full;

    const sfc_width: i32 = surface.getWidth();
    const sfc_width_scaled: i32 = sfc_width * scale;
    const sfc_height: i32 = surface.getHeight();
    const _precision = if (operator.requiresFloat()) .float else precision;
    if (!polygons.inBox(scale, surface.getWidth(), surface.getHeight())) {
        return;
    }

    // Our draw methodology is actually quite similar to paintDirect in that we
    // composite per-scanline, versus the supersample approach where we create
    // a mask first, downsample, it, and then paint that to a particular
    // location. As such, our draw area is taken as a scanline range, versus a
    // box.
    const start_scanline: i32 = math.clamp(
        @as(i32, @intFromFloat(@floor(polygons.extent_top / scale))),
        0,
        sfc_height - 1,
    );
    // NOTE: The clamping on end_scanline to (sfc_height - 1) versus sfc_height
    // has been shipped from paintDirect. This is apparently designed to catch
    // single-line-height cases, but reviewing the code there (and here), this
    // is only employed in scanline iteration and could probably use a review.
    //
    // For now though, we're leaving it alone, but note that scanline_end_x
    // below "correctly" clamps to the surface width as it does not necessarily
    // need to worry about scanlines, but rather controls the x-bounds of the
    // draw area for both the coverage buffer length and also clear area for
    // unbounded operations.
    const end_scanline: i32 = math.clamp(
        @as(i32, @intFromFloat(@ceil(polygons.extent_bottom / scale))),
        start_scanline,
        sfc_height - 1,
    );

    // We create our coverage buffer once and reset it separately, this is
    // because reset is simple so we don't need to tie it into the arena.
    const scanline_start_x: i32 = math.clamp(
        @as(i32, @intFromFloat(@floor(polygons.extent_left / scale))),
        0,
        sfc_width - 1,
    );
    // NOTE: The end clamping here has to be properly synced with the (scaled)
    // end_x in the individual sub-scanline loop (which is clamped to
    // sfc_width_scaled).
    const scanline_end_x: i32 = math.clamp(
        @as(i32, @intFromFloat(@ceil(polygons.extent_right / scale))),
        scanline_start_x,
        sfc_width,
    );

    const scanline_draw_width = scanline_end_x - scanline_start_x;
    if (scanline_draw_width < 1) {
        // Should have already been validated by inBox
        @panic("invalid mask dimensions. this is a bug, please report it");
    }
    var coverage_buffer = try SparseCoverageBuffer.init(alloc, @max(0, scanline_draw_width));
    defer coverage_buffer.deinit(alloc);

    // We need a scaled x-offset that we need to use when adding spans
    // (subtracting/pulling back) or drawing out spans (adding/pushing
    // forward).
    const scanline_start_x_scaled = scanline_start_x * scale;

    // Make an ArenaAllocator for our edges, this allows us to re-use the
    // same memory after every scanline by simply resetting the arena.
    var edge_arena = heap.ArenaAllocator.init(alloc);
    defer edge_arena.deinit();
    const edge_alloc = edge_arena.allocator();

    // Clear out the area not covered by the draw area when we're dealing with
    // unbounded operators.
    if (!operator.isBounded()) {
        const ClearStrideFn = struct {
            fn f(sfc: *Surface, scy: i32, width: usize) void {
                const clear_stride = sfc.getStride(0, scy, width);
                compositor.StrideCompositor.run(clear_stride, &.{.{
                    .operator = .clear,
                    .src = .{ .pixel = .{ .rgba = .{ .r = 0, .g = 0, .b = 0, .a = 0 } } },
                }}, .{ .precision = .integer });
            }
        };

        // Do any full scanlines first
        for (0..@max(0, start_scanline)) |y_u|
            ClearStrideFn.f(surface, @intCast(y_u), @max(0, sfc_width));
        for (@max(0, end_scanline + 1)..@max(0, sfc_width)) |y_u|
            ClearStrideFn.f(surface, @intCast(y_u), @max(0, sfc_width));

        // Now, do the strides outside of the draw area on the same scanlines
        for (@max(0, start_scanline)..@max(0, end_scanline) + 1) |y_u| {
            if (scanline_start_x > 0) ClearStrideFn.f(surface, @intCast(y_u), @max(0, scanline_start_x));
            if (scanline_end_x < sfc_width) {
                ClearStrideFn.f(surface, @intCast(y_u), @max(0, sfc_width - scanline_end_x));
            }
        }
    }

    for (@max(0, start_scanline)..@max(0, end_scanline) + 1) |y_u| {
        defer {
            _ = edge_arena.reset(.retain_capacity);
            coverage_buffer.reset();
        }
        const y: i32 = @intCast(y_u);

        const y_scaled: i32 = y * scale;
        for (0..4) |y_offset| {
            const y_scanline_scaled: i32 = y_scaled + @as(i32, @intCast(y_offset));
            var edge_list = try polygons.xEdgesForY(
                edge_alloc,
                @floatFromInt(y_scanline_scaled),
                fill_rule,
            );
            defer edge_list.deinit(edge_alloc);

            // x_min controls the last x-position on the scanline we've
            // recorded (i.e., the end of the last span) and serves as the
            // minimum that the next span can start at. This is a safety
            // measure to ensure that no span overlaps can cause issues with
            // coverage overflowing, etc.
            var x_min: i32 = 0;

            for (0..edge_list.items.len / 2) |edge_pair_idx| {
                const edge_pair_start = edge_pair_idx * 2;
                // Pull back the scaled device space co-ordinates (similar to
                // supersample).
                const start_x: i32 = math.clamp(
                    edge_list.items[edge_pair_start] - scanline_start_x_scaled,
                    x_min,
                    sfc_width_scaled - 1,
                );
                // NOTE: The end clamping here has to be properly synced with
                // the (unscaled) scanline_end_x, found closer to coverage
                // buffer initialization (used to calculate the buffer length,
                // and clamped to sfc_width).
                const end_x: i32 = math.clamp(
                    edge_list.items[edge_pair_start + 1] - scanline_start_x_scaled,
                    start_x,
                    sfc_width_scaled,
                );
                const fill_len: i32 = end_x - start_x;

                if (fill_len > 0) {
                    coverage_buffer.addSpan(@max(0, start_x), @max(0, fill_len));
                }

                x_min = end_x;
            }
        }

        // Make sure we can't go beyond the actual capacity of the coverage
        // buffer (guard against bad recorded span len)
        const coverage_x_max = @min(coverage_buffer.len, coverage_buffer.capacity);
        // Write out all of the values in our scanline coverage buffer.
        var coverage_x_u: u32 = 0;
        while (coverage_x_u < coverage_x_max) {
            // Apply our offset to the co-ordinates in the scanline buffer
            const x: i32 = @as(i32, @intCast(coverage_x_u)) + scanline_start_x;
            const coverage_val_raw, const coverage_len_raw = coverage_buffer.get(coverage_x_u);
            // Clamp our coverage values (guards against uninitialized values
            // in the sparse buffer)
            const coverage_val: u8 = math.clamp(coverage_val_raw, 0, coverage_full);
            const coverage_len: u32 = @min(coverage_len_raw, @max(0, sfc_width - x));
            switch (coverage_val) {
                0 => {}, // Skip zero entries
                coverage_full => {
                    // Fully opaque span, so we can just composite directly (no alpha).
                    const dst_stride = surface.getStride(x, y, coverage_len);
                    compositor.StrideCompositor.run(dst_stride, &.{.{
                        .operator = operator,
                        .src = switch (pattern.*) {
                            .opaque_pattern => .{ .pixel = pattern.opaque_pattern.pixel },
                            .gradient => |g| .{ .gradient = .{
                                .underlying = g,
                                .x = x,
                                .y = y,
                            } },
                            .dither => .{ .dither = .{
                                .underlying = pattern.dither,
                                .x = x,
                                .y = y,
                            } },
                        },
                    }}, .{ .precision = _precision });
                },
                else => {
                    // Span with some degree of (> 0, < max) opacity, so we
                    // need to grab that value, turn it into an alpha8 pixel,
                    // and composite that across our span.
                    const dst_stride = surface.getStride(x, y, coverage_len);
                    const mask_px: pixel.Pixel = .{ .alpha8 = .{
                        .a = @intCast(math.clamp(coverage_val * alpha_scale - 1, 0, 255)),
                    } };
                    compositor.StrideCompositor.run(dst_stride, &.{
                        .{
                            .operator = .dst_in,
                            .dst = switch (pattern.*) {
                                .opaque_pattern => .{ .pixel = pattern.opaque_pattern.pixel },
                                .gradient => |g| .{ .gradient = .{
                                    .underlying = g,
                                    .x = x,
                                    .y = y,
                                } },
                                .dither => .{ .dither = .{
                                    .underlying = pattern.dither,
                                    .x = x,
                                    .y = y,
                                } },
                            },
                            .src = .{ .pixel = mask_px },
                        },
                        .{
                            .operator = operator,
                        },
                    }, .{ .precision = precision });
                },
            }

            coverage_x_u += coverage_len; // Advance to next buffer entry
        }
    }
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
