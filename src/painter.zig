// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024-2025 Chris Marchesi

//! Contains unmanaged painter functions for filling and stroking.

const mem = @import("std").mem;
const testing = @import("std").testing;

const compositor = @import("compositor.zig");
const options = @import("options.zig");

const fill_plotter = @import("internal/tess/fill_plotter.zig");
const polyline_plotter = @import("internal/tess/polyline_plotter.zig");
const stroke_plotter = @import("internal/tess/stroke_plotter.zig");

const Pattern = @import("pattern.zig").Pattern;
const Surface = @import("surface.zig").Surface;
const Transformation = @import("Transformation.zig");
const InternalError = @import("internal/InternalError.zig").InternalError;
const PathNode = @import("internal/path_nodes.zig").PathNode;
const direct_rasterizer = @import("internal/raster/direct.zig");
const hairline_rasterizer = @import("internal/raster/hairline.zig");
const multisample_rasterizer = @import("internal/raster/multisample.zig");
const supersample_rasterizer = @import("internal/raster/supersample.zig");
const SparseCoverageBuffer = @import("internal/raster/sparse_coverage.zig").SparseCoverageBuffer;
const supersample_scale = @import("surface.zig").supersample_scale;

pub const FillOptions = struct {
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

    /// The single-pixel source data is an RGB-with-alpha-channel type, but the
    /// value has not been correctly pre-multiplied and will cause overflows
    /// with compositing. See `pixel.ARGB` or `pixel.RGBA` for more details.
    PixelSourceNotPreMultiplied,
} || Surface.Error || InternalError || mem.Allocator.Error;

/// Runs a fill operation on the path set represented by `nodes`.
pub fn fill(
    alloc: mem.Allocator,
    surface: *Surface,
    pattern: *const Pattern,
    nodes: []const PathNode,
    opts: FillOptions,
) FillError!void {
    switch (pattern.*) {
        .opaque_pattern => |o| switch (o.pixel) {
            inline .argb, .rgba => |px| if (!px.canDemultiply()) return error.PixelSourceNotPreMultiplied,
            else => {},
        },
        else => {},
    }

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
        .default, .multisample_4x => multisample_rasterizer.scale,
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
            try direct_rasterizer.run(
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
            try supersample_rasterizer.run(
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
            try multisample_rasterizer.run(
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

pub const StrokeOptions = struct {
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

    /// Sets hairline mode. In hairline mode, all lines are drawn using their
    /// minimum line width (effectively zero or one pixel or display unit,
    /// depending on the implementation).
    ///
    /// This option ignores several other options, such as line cap and join
    /// modes, and other associated options such as miter limit, line width,
    /// and the transformation matrix.
    hairline: bool = false,
};

/// Errors related to the `stroke` operation.
///
/// **Note for autodoc viewers:** `std.mem.Allocator.Error` is a member of this
/// set, but is not shown because `std` is pruned from our autodoc.
pub const StrokeError = error{
    /// The single-pixel source data is an RGB-with-alpha-channel type, but the
    /// value has not been correctly pre-multiplied and will cause overflows
    /// with compositing. See `pixel.ARGB` or `pixel.RGBA` for more details.
    PixelSourceNotPreMultiplied,
} || Transformation.Error || Surface.Error || InternalError || mem.Allocator.Error;

/// Runs a stroke operation on the path set represented by `nodes`. The path(s)
/// is/are transformed to one or more polygon(s) representing the line(s),
/// which are then filled.
pub fn stroke(
    alloc: mem.Allocator,
    surface: *Surface,
    pattern: *const Pattern,
    nodes: []const PathNode,
    opts: StrokeOptions,
) StrokeError!void {
    switch (pattern.*) {
        .opaque_pattern => |o| switch (o.pixel) {
            inline .argb, .rgba => |px| if (!px.canDemultiply()) return error.PixelSourceNotPreMultiplied,
            else => {},
        },
        else => {},
    }

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

    // We can fast-path here if we're using hairline stroking.
    if (opts.hairline) {
        var contours = try polyline_plotter.plot(
            alloc,
            nodes,
            opts.tolerance,
            opts.dashes,
            opts.dash_offset,
        );
        defer contours.deinit(alloc);
        hairline_rasterizer.run(
            surface,
            pattern,
            contours,
            opts.operator,
            opts.precision,
            opts.anti_aliasing_mode,
        );
        return;
    }

    const scale: f64 = switch (aa_mode) {
        .none => 1,
        .supersample_4x => supersample_scale,
        .default, .multisample_4x => multisample_rasterizer.scale,
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
            try direct_rasterizer.run(
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
            try supersample_rasterizer.run(
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
            try multisample_rasterizer.run(
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

test "fill, non pre-multiplied pixel" {
    var sfc = try Surface.init(.image_surface_rgb, testing.allocator, 1, 1);
    defer sfc.deinit(testing.allocator);
    try testing.expectError(error.PixelSourceNotPreMultiplied, fill(
        testing.allocator,
        &sfc,
        &.{
            .opaque_pattern = .{
                .pixel = .{ .rgba = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF, .a = 0xAA } },
            },
        },
        &.{},
        .{},
    ));
}

test "stroke, non pre-multiplied pixel" {
    var sfc = try Surface.init(.image_surface_rgb, testing.allocator, 1, 1);
    defer sfc.deinit(testing.allocator);
    try testing.expectError(error.PixelSourceNotPreMultiplied, stroke(
        testing.allocator,
        &sfc,
        &.{
            .opaque_pattern = .{
                .pixel = .{ .rgba = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF, .a = 0xAA } },
            },
        },
        &.{},
        .{},
    ));
}
