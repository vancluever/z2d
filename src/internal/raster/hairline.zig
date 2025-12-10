// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024-2025 Chris Marchesi

//! Various hairline stroking functions. These functions draw at the minimum
//! technical stroke width (1 pixel). Note that it is possible to get widths
//! smaller than this with the standard polygon stroker, but sub-1-pixel line
//! widths will usually yield artifacts, and as such a small width is only
//! really useful with a transform that can widen the width after.
//!
//! These functions ensure a hairline is properly drawn. However, they don't
//! support things like caps or joins.
//!
//! Note that these technically don't "raster", but we've put them in this
//! context for a lack of a better name.
const math = @import("std").math;
const testing = @import("std").testing;

const AntiAliasMode = @import("../../options.zig").AntiAliasMode;
const Surface = @import("../../surface.zig").Surface;
const Pattern = @import("../../pattern.zig").Pattern;
const Contour = @import("../tess/Polygon.zig").Contour;
const Point = @import("../Point.zig");

const compositor = @import("../../compositor.zig");
const pixel = @import("../../pixel.zig");
const compositeOpaque = @import("shared.zig").compositeOpaque;
const compositeOpacity = @import("shared.zig").compositeOpacity;

pub fn run(
    surface: *Surface,
    pattern: *const Pattern,
    contours: Contour.List,
    operator: compositor.Operator,
    precision: compositor.Precision,
    aa_mode: AntiAliasMode,
) void {
    const effective_precision = if (operator.requiresFloat()) .float else precision;
    for (contours.list.items) |contour| {
        switch (contour.len) {
            0 => {},
            1 => {
                const point = Contour.Corner.fromNode(contour.corners.first.?).point;
                // NOTE: OOB co-ordinates are handled by the surface, see
                // documentation for Surface.paintStride, Surface.getStride,
                // and Surface.compositeStride for details).
                compositeOpaque(
                    operator,
                    surface,
                    pattern,
                    @intFromFloat(@round(point.x)),
                    @intFromFloat(@round(point.y)),
                    1,
                    effective_precision,
                );
            },
            else => {
                var points: [2]Point = undefined;
                points[0] = Contour.Corner.fromNode(contour.corners.first.?).point;
                var idx: u1 = 1;
                var node_ = contour.corners.first.?.next;
                while (node_) |node| {
                    points[idx] = Contour.Corner.fromNode(node).point;
                    drawLine(
                        .{
                            .surface = surface,
                            .pattern = pattern,
                            .operator = operator,
                            .precision = effective_precision,
                            .aa_mode = aa_mode,
                        },
                        @intFromFloat(@round(points[0].x)),
                        @intFromFloat(@round(points[0].y)),
                        @intFromFloat(@round(points[1].x)),
                        @intFromFloat(@round(points[1].y)),
                    );
                    idx ^= 1;
                    node_ = node.next;
                }
            },
        }
    }
}

const DrawOptions = struct {
    surface: *Surface,
    pattern: *const Pattern,
    operator: compositor.Operator,
    precision: compositor.Precision,
    aa_mode: AntiAliasMode,
};

fn drawLine(opts: DrawOptions, x0: i32, y0: i32, x1: i32, y1: i32) void {
    // We do a full box check here, and clipping in the fast-path functions.
    // Note, however, that due to how clipping complicates the Bresenham and Wu
    // algorithms, we rely on the surface implementation to do bounds checking
    // (since we only draw 1 pixel at a time, we can rely on the start x and y
    // co-ordinate check in the underlying surface; see documentation for
    // Surface.paintStride, Surface.getStride, and Surface.compositeStride for
    // details).
    if (!inBox(opts.surface, x0, y0, x1, y1)) {
        return;
    }

    const dx: u32 = @abs(x1 - x0);
    const dy: u32 = @abs(y1 - y0);
    if (dx == 0) {
        drawVertical(opts, x0, y0, y1);
    } else if (dy == 0) {
        drawHorizontal(opts, x0, x1, y0);
    } else if (dx < dy) {
        switch (opts.aa_mode) {
            .none => drawBresVertical(opts, x0, y0, x1, y1),
            else => drawWuVertical(opts, x0, y0, x1, y1),
        }
    } else {
        switch (opts.aa_mode) {
            .none => drawBresHorizontal(opts, x0, y0, x1, y1),
            else => drawWuHorizontal(opts, x0, y0, x1, y1),
        }
    }
}

fn drawHorizontal(opts: DrawOptions, x0: i32, x1: i32, y: i32) void {
    const start_x: i32 = math.clamp(@min(x0, x1), 0, opts.surface.getWidth() - 1);
    const end_x: i32 = math.clamp(@max(x0, x1), 0, opts.surface.getWidth() - 1);
    const len: i32 = end_x - start_x + 1;
    if (len > 0) {
        compositeOpaque(
            opts.operator,
            opts.surface,
            opts.pattern,
            start_x,
            y,
            @intCast(len),
            opts.precision,
        );
    }
}

fn drawVertical(opts: DrawOptions, x: i32, y0: i32, y1: i32) void {
    const start_y: u32 = @intCast(math.clamp(@min(y0, y1), 0, opts.surface.getHeight() - 1));
    const end_y: u32 = @intCast(math.clamp(@max(y0, y1), 0, opts.surface.getHeight() - 1));

    for (start_y..end_y + 1) |y_u| {
        const y_i: i32 = @intCast(y_u);
        compositeOpaque(
            opts.operator,
            opts.surface,
            opts.pattern,
            x,
            y_i,
            1,
            opts.precision,
        );
    }
}

fn drawBresHorizontal(opts: DrawOptions, x0: i32, y0: i32, x1: i32, y1: i32) void {
    if (x0 > x1) {
        // Reverse our lines as the major axis is out-of-order
        return drawBresHorizontal(opts, x1, y1, x0, y0);
    }

    const dx = x1 - x0;
    const dy, const sy = deltaStep(y0, y1);

    var x: i32 = x0;
    var y: i32 = y0;
    var d: i32 = 2 * dy - dx; // Decision parameter
    const d_inc = 2 * dy; // Decision increment
    const d_dec = 2 * dx; // Decision decrement

    while (x <= x1) : (x += 1) {
        compositeOpaque(
            opts.operator,
            opts.surface,
            opts.pattern,
            x,
            y,
            1,
            opts.precision,
        );
        if (d > 0) {
            y += sy;
            d -= d_dec;
        }
        d += d_inc;
    }
}

// See drawBresHorizontal for details.
fn drawBresVertical(opts: DrawOptions, x0: i32, y0: i32, x1: i32, y1: i32) void {
    if (y0 > y1) {
        return drawBresVertical(opts, x1, y1, x0, y0);
    }

    const dy = y1 - y0;
    const dx, const sx = deltaStep(x0, x1);

    var x: i32 = x0;
    var y: i32 = y0;
    var d: i32 = 2 * dx - dy;
    const d_inc = 2 * dx;
    const d_dec = 2 * dy;

    while (y <= y1) : (y += 1) {
        compositeOpaque(
            opts.operator,
            opts.surface,
            opts.pattern,
            x,
            y,
            1,
            opts.precision,
        );
        if (d > 0) {
            x += sx;
            d -= d_dec;
        }
        d += d_inc;
    }
}

fn drawWuHorizontal(opts: DrawOptions, x0: i32, y0: i32, x1: i32, y1: i32) void {
    // NOTE: We're using static stuff here: our error is u16, opacity is u8.
    if (x0 > x1) {
        // Reverse our lines as the major axis is out-of-order
        return drawWuHorizontal(opts, x1, y1, x0, y0);
    }

    const dx = x1 - x0;
    const dy, const sy = deltaStep(y0, y1);

    var x: i32 = x0;
    var y: i32 = y0;

    // Decision parameter and increment, see the errInc helper for more
    // details.
    var err: u16 = 0;
    const err_inc: u16 = errInc(dy, dx);

    // First pixel is full intensity
    compositeOpaque(
        opts.operator,
        opts.surface,
        opts.pattern,
        x,
        y,
        1,
        opts.precision,
    );
    x += 1;

    while (x < x1) : (x += 1) {
        err, const overflow = @addWithOverflow(err, err_inc);
        if (overflow == 1) {
            // Error rolled over, so increment y
            y += sy;
        }

        // Shift down the error. This gives us the *complement* to our opacity,
        // not the opacity itself. This is because error dictates how much in
        // the center we are, so no error means fully in the middle, and hence
        // full opacity.
        const opacity_complement: u8 = @intCast(err >> 8);
        compositeOpacity(
            opts.operator,
            opts.surface,
            opts.pattern,
            x,
            y,
            1,
            opts.precision,
            opacity_complement ^ 0xFF,
        );
        compositeOpacity(
            opts.operator,
            opts.surface,
            opts.pattern,
            x,
            y + sy,
            1,
            opts.precision,
            opacity_complement,
        );
    }

    // Last pixel is full intensity
    compositeOpaque(
        opts.operator,
        opts.surface,
        opts.pattern,
        x1,
        y1,
        1,
        opts.precision,
    );
}

// See drawWuHorizontal for details.
fn drawWuVertical(opts: DrawOptions, x0: i32, y0: i32, x1: i32, y1: i32) void {
    if (y0 > y1) {
        return drawWuVertical(opts, x1, y1, x0, y0);
    }

    const dy = y1 - y0;
    const dx, const sx = deltaStep(x0, x1);

    var x: i32 = x0;
    var y: i32 = y0;

    var err: u16 = 0;
    const err_inc: u16 = errInc(dx, dy);

    compositeOpaque(
        opts.operator,
        opts.surface,
        opts.pattern,
        x,
        y,
        1,
        opts.precision,
    );
    y += 1;

    while (y < y1) : (y += 1) {
        err, const overflow = @addWithOverflow(err, err_inc);
        if (overflow == 1) {
            x += sx;
        }

        const opacity_complement: u8 = @intCast(err >> 8);
        compositeOpacity(
            opts.operator,
            opts.surface,
            opts.pattern,
            x,
            y,
            1,
            opts.precision,
            opacity_complement ^ 0xFF,
        );
        compositeOpacity(
            opts.operator,
            opts.surface,
            opts.pattern,
            x + sx,
            y,
            1,
            opts.precision,
            opacity_complement,
        );
    }

    compositeOpaque(
        opts.operator,
        opts.surface,
        opts.pattern,
        x1,
        y1,
        1,
        opts.precision,
    );
}

/// Calculates a delta and step value for the minor axis in both Bresenham and
/// Xiaolin Wu algorithms. This enables a single version of each of these
/// algorithms to operate on both directions on the minor axis.
fn deltaStep(a: i32, b: i32) struct { i32, i2 } {
    const c = b - a;
    if (c < 0) {
        return .{ -c, -1 };
    }
    return .{ c, 1 };
}

/// Calculates an error increment as ((a << 16) / b) for use in Xiaolin Wu line
/// algorithms.
///
/// In the Wu algorithm, the error variable is stored as an unsigned value that
/// is representative of the slope (a fully fractional value less than one);
/// contrast this with Bresenham where the decision parameter is stored as a
/// signed reduction of the slope, which fully avoids division. As a completely
/// fractional value would, rollover dictates when to advance, versus the
/// decision parameter being greater than zero.
fn errInc(a: i32, b: i32) u16 {
    if (a == b) {
        // Guards against dx == dy. Note that this case should always be
        // fast-pathed outside of the Wu algorithm (or even Bresenham, for that
        // matter).
        return math.maxInt(u16);
    }
    const c: u32 = @as(u32, @intCast(a)) << 16;
    const d: u32 = @intCast(b);
    return @intCast(c / d);
}

fn inBox(surface: *Surface, x0: i32, y0: i32, x1: i32, y1: i32) bool {
    if ((x0 < 0 or x0 >= surface.getWidth()) and (x1 < 0 or x1 >= surface.getWidth())) {
        return false;
    }

    if ((y0 < 0 or y0 >= surface.getHeight()) and (y1 < 0 or y1 >= surface.getHeight())) {
        return false;
    }

    return true;
}
