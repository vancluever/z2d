// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024-2025 Chris Marchesi

//! Contains types and utility functions for gradients.

const std = @import("std");
const debug = @import("std").debug;
const math = @import("std").math;
const mem = @import("std").mem;
const testing = @import("std").testing;

const colorpkg = @import("color.zig");
const pixel = @import("pixel.zig");

const Color = colorpkg.Color;
const InterpolationMethod = colorpkg.InterpolationMethod;
const Pattern = @import("pattern.zig").Pattern;
const Point = @import("internal/Point.zig");
const Transformation = @import("Transformation.zig");

const runCases = @import("internal/util.zig").runCases;
const TestingError = @import("internal/util.zig").TestingError;

/// Interface tags for gradient types.
pub const GradientType = enum {
    linear,
    radial,
    conic,
};

/// Gradients are patterns that can be used to draw colors in a
/// position-dependent fashion, transitioning through a series of colors along
/// a specific axis.
///
/// Gradients operate off of the higher-level `Color` types, returning these
/// values with which further interpolation can be done (when manually
/// searching off of `searchInStops`), or translated to an RGBA pixel value
/// using `getPixel`.
///
/// Any methods that require an allocator must use the same allocator for the
/// life of the gradient.
pub const Gradient = union(GradientType) {
    linear: Linear,
    radial: Radial,
    conic: Conic,

    /// Arguments for the `init` function.
    pub const InitArgs = struct {
        /// The type of the gradient along with the parameters common to that
        /// gradient for initialization.
        type: union(GradientType) {
            /// Represents a linear gradient going from `(x0, y0)` to `(x1, y1)`.
            linear: struct {
                x0: f64,
                y0: f64,
                x1: f64,
                y1: f64,
            },

            /// Represents a radial gradient represented by two circles,
            /// positioned at `(inner_x, inner_y)` and `(outer_x, outer_y)`,
            /// with radii `inner_radius` and `outer_radius`.
            ///
            /// To understand how this gradient works, you can imagine looking
            /// at the gradient from 3D space as a cone, looking down from the
            /// inner circle at the top.
            ///
            /// To represent a basic single-point radial gradient, use the same
            /// co-ordinates for both circles and make `inner_radius` zero.
            radial: struct {
                inner_x: f64,
                inner_y: f64,
                inner_radius: f64,
                outer_x: f64,
                outer_y: f64,
                outer_radius: f64,
            },

            /// Represents a conic (sweep) gradient, centered at `(x, y)`. The
            /// gradient runs around the center point starting at `angle`.
            conic: struct {
                x: f64,
                y: f64,
                angle: f64,
            },
        },

        /// The interpolation method to use with this gradient.
        method: InterpolationMethod = .linear_rgb,

        /// Can be used to supply a static buffer for color stops. If you use
        /// this, use `addStopAssumeCapacity` and don't call `deinit` when you
        /// are finished with the gradient.
        stops: []Stop = &[_]Stop{},
    };

    /// Initializes the gradient with the specified type and arguments.
    ///
    /// Before using the gradient, it's recommended to add some stops:
    ///
    /// ```
    /// var gradient = Gradient.init(.{
    ///     .type = .{ .linear = .{
    ///         .x0 = 0,  .y0 = 0,
    ///         .x1 = 99, .y1 = 99,
    ///     }},
    ///     .method = .linear_rgb,
    /// });
    /// defer gradient.deinit(alloc);
    /// try gradient.addStop(alloc, 0,   .{ .rgb = .{ 1, 0, 0 } });
    /// try gradient.addStop(alloc, 0.5, .{ .rgb = .{ 0, 1, 0 } });
    /// try gradient.addStop(alloc, 1,   .{ .rgb = .{ 0, 0, 1 } });
    /// ...
    /// ```
    ///
    /// Stop memory can be managed by either using `addStop` with an allocator;
    /// if using this method `deinit` must be called to release the stops. You
    /// can also supply your own buffer via `InitArgs.stops` and using
    /// `addStopAssumeCapacity`; if done this way, `deinit` should not be
    /// called.
    pub fn init(args: InitArgs) Gradient {
        return switch (args.type) {
            .linear => |l| Linear.initBuffer(
                l.x0,
                l.y0,
                l.x1,
                l.y1,
                args.stops,
                args.method,
            ).asGradientInterface(),
            .radial => |r| Radial.initBuffer(
                r.inner_x,
                r.inner_y,
                r.inner_radius,
                r.outer_x,
                r.outer_y,
                r.outer_radius,
                args.stops,
                args.method,
            ).asGradientInterface(),
            .conic => |c| Conic.initBuffer(
                c.x,
                c.y,
                c.angle,
                args.stops,
                args.method,
            ).asGradientInterface(),
        };
    }

    /// Releases any stops that have been added using `addStop`. Must use the
    /// same allocator that was used there.
    pub fn deinit(self: *Gradient, alloc: mem.Allocator) void {
        switch (self.*) {
            inline else => |*g| g.deinit(alloc),
        }
    }

    /// Shorthand for returning the gradient as a pattern.
    pub fn asPattern(self: *Gradient) Pattern {
        return .{ .gradient = self };
    }

    /// Adds a stop with the specified offset and color. The offset will be
    /// clamped to `0.0` and `1.0`.
    ///
    /// If stops are added at identical offsets, they will be stored in the
    /// order they were added. This can be used to define "hard stops" - parts
    /// of gradients that transition from one color to another directly without
    /// interpolation.
    ///
    /// Note that hard stops are not anti-aliased. To achieve a similar
    /// smoothing effect, one can add a slightly small offset to one side of
    /// the hard stop to produce a small amount of interpolation:
    ///
    /// ```
    /// try gradient.addStop(alloc, 0,   .{ .rgb = .{ 1, 0, 0 } });
    /// try gradient.addStop(alloc, 0.5, .{ .rgb = .{ 1, 0, 0 } });
    /// try gradient.addStop(alloc, 0.501, .{ .rgb = .{ 0, 1, 0 } });
    /// try gradient.addStop(alloc, 1,   .{ .rgb = .{ 0, 1, 0 } });
    /// ```
    pub fn addStop(
        self: *Gradient,
        alloc: mem.Allocator,
        offset: f32,
        color: Color.InitArgs,
    ) mem.Allocator.Error!void {
        return switch (self.*) {
            inline else => |*g| g.stops.add(alloc, offset, color),
        };
    }

    /// Like `addStop`, but assumes the list can hold the stop.
    pub fn addStopAssumeCapacity(self: *Gradient, offset: f32, color: Color.InitArgs) void {
        switch (self.*) {
            inline else => |*g| g.stops.addAssumeCapacity(offset, color),
        }
    }

    /// Sets the transformation matrix for this gradient.
    ///
    /// When working with this function, keep in mind that gradients are
    /// expected to operate in _pattern space_ in the overall pattern space ->
    /// user space -> device space co-ordinate model. This effectively means
    /// that the inverse of whatever matrix is supplied here is used. If
    /// working with gradients directly and you are looking for a
    /// transformation, make sure you keep this in mind when setting the matrix
    /// (either apply the inverse or manually invert your transformations
    /// before applying them).
    ///
    /// `Context` runs this function when `Context.setPattern` is called.
    pub fn setTransformation(self: *Gradient, tr: Transformation) Transformation.Error!void {
        return switch (self.*) {
            inline else => |*g| g.setTransformation(tr),
        };
    }

    /// Gets the pixel calculated for the gradient at `(x, y)`.
    pub fn getPixel(self: *const Gradient, x: i32, y: i32) pixel.Pixel {
        return switch (self.*) {
            inline else => |*g| g.getPixel(x, y),
        };
    }

    /// Returns the offset on the gradient for the specific (x, y)
    /// co-ordinates. This offset can be used to manually search on the
    /// gradient's stops using `searchInStops`.
    ///
    /// ```
    /// const offset = gradient.getOffset(50, 50);
    /// const result = gradient.searchInStops(offset);
    /// ... // (lerp off of search result or perform other operations)
    /// ```
    ///
    /// Negative values denote an invalid result due to a zero-length gradient
    /// and is valid to give to `searchInStops` (will return a transparent
    /// black color result).
    pub fn getOffset(self: *const Gradient, x: i32, y: i32) f32 {
        return switch (self.*) {
            inline else => |*g| g.getOffset(x, y),
        };
    }

    /// Returns a start color, an end color, and a relative offset within the
    /// stop list, suitable for linear interpolation.
    ///
    /// Offset is clamped to `0.0` and `1.0`, with the exception of negative
    /// values (our way to denote an invalid t result from `getOffset` calls)
    /// which return transparent black.
    ///
    /// The result of a gradient with no stops is also transparent black.
    pub fn searchInStops(self: *const Gradient, offset: f32) Stop.List.SearchResult {
        return switch (self.*) {
            inline else => |*g| g.stops.search(offset),
        };
    }

    /// Returns the interpolation method for the gradient.
    pub fn getInterpolationMethod(self: *const Gradient) InterpolationMethod {
        return switch (self.*) {
            inline else => |*g| g.stops.interpolation_method,
        };
    }
};

/// Represents a linear gradient along a line.
pub const Linear = struct {
    start: Point,
    end: Point,
    transformation: Transformation = Transformation.identity,

    /// The stops contained within the gradient. Add stops using
    /// `Stop.List.add` or `Stop.List.addAssumeCapacity`.
    stops: Stop.List,

    /// Initializes the gradient with externally allocated memory for the
    /// stops. Do not use this with `deinit` or `Stop.List.add` as it will
    /// cause illegal behavior, use `Stop.List.addAssumeCapacity` instead.
    pub fn initBuffer(
        x0: f64,
        y0: f64,
        x1: f64,
        y1: f64,
        stops: []Stop,
        method: InterpolationMethod,
    ) Linear {
        return .{
            .start = .{ .x = x0, .y = y0 },
            .end = .{ .x = x1, .y = y1 },
            .stops = .{
                .l = std.ArrayListUnmanaged(Stop).initBuffer(stops),
                .interpolation_method = method,
            },
        };
    }

    /// Releases any stops that have been added using `Stop.List.add`. Must use
    /// the same allocator that was used there.
    pub fn deinit(self: *Linear, alloc: mem.Allocator) void {
        self.stops.deinit(alloc);
    }

    /// Returns this gradient as a higher-level gradient interface.
    pub fn asGradientInterface(self: Linear) Gradient {
        return .{ .linear = self };
    }

    /// Sets the transformation matrix for this gradient.
    ///
    /// When working with this function, keep in mind that gradients are
    /// expected to operate in _pattern space_ in the overall pattern space ->
    /// user space -> device space co-ordinate model. This effectively means
    /// that the inverse of whatever matrix is supplied here is used. If
    /// working with gradients directly and you are looking for a
    /// transformation, make sure you keep this in mind when setting the matrix
    /// (either apply the inverse or manually invert your transformations
    /// before applying them).
    ///
    /// `Context` runs this function when `Context.setPattern` is called.
    pub fn setTransformation(self: *Linear, tr: Transformation) Transformation.Error!void {
        self.transformation = try tr.inverse();
    }

    /// Gets the pixel calculated for the gradient at `(x, y)`.
    pub fn getPixel(self: *const Linear, x: i32, y: i32) pixel.Pixel {
        const search_result = self.stops.search(self.getOffset(x, y));
        return self.stops.interpolation_method.interpolateEncode(
            search_result.c0,
            search_result.c1,
            search_result.offset,
        ).asPixel();
    }

    /// Performs orthogonal projection on the gradient, transforming the
    /// supplied (x, y) co-ordinates into an offset. This offset can be used to
    /// manually search on the gradient's stops using `Stop.List.search`.
    ///
    /// ```
    /// const offset = gradient.getOffset(50, 50);
    /// const result = gradient.stops.search(offset);
    /// ... // (lerp off of search result or perform other operations)
    /// ```
    ///
    /// Negative values denote an invalid result due to a zero-length gradient
    /// and is valid to give to `Stop.List.search` (will return a transparent
    /// black color result).
    pub fn getOffset(self: *const Linear, x: i32, y: i32) f32 {
        var px: f64 = @as(f64, @floatFromInt(x)) + 0.5;
        var py: f64 = @as(f64, @floatFromInt(y)) + 0.5;
        if (!self.transformation.equal(Transformation.identity)) {
            self.transformation.userToDevice(&px, &py);
        }
        const start_to_end_dx = self.end.x - self.start.x;
        const start_to_end_dy = self.end.y - self.start.y;
        const gradient_distance = dotSq(start_to_end_dx, start_to_end_dy);
        if (gradient_distance == 0) return -1;
        const inv_dist = 1 / gradient_distance;
        const start_to_p_dx = px - self.start.x;
        const start_to_p_dy = py - self.start.y;
        return @floatCast(math.clamp(
            dot(
                f64,
                2,
                .{ start_to_end_dx, start_to_end_dy },
                .{ start_to_p_dx, start_to_p_dy },
            ) * inv_dist,
            0,
            1,
        ));
    }
};

/// Represents a 2-circle radial gradient. By controlling the two circles'
/// co-ordinates and radii, one can control the rate of projection along the
/// radial line.
pub const Radial = struct {
    inner: Point,
    inner_radius: f64,
    outer: Point,
    outer_radius: f64,
    transformation: Transformation = Transformation.identity,

    // Pre-calculation fields for finding the t value that can be done ahead of
    // time.
    cdx: f64,
    cdy: f64,
    dr: f64,
    min_dr: f64,
    a: f64,
    inv_a: f64,

    /// The stops contained within the gradient. Add stops using
    /// `Stop.List.add` or `Stop.List.addAssumeCapacity`.
    stops: Stop.List,

    /// Initializes the gradient with externally allocated memory for the
    /// stops. Do not use this with `deinit` or `Stop.List.add` as it will
    /// cause illegal behavior, use `Stop.List.addAssumeCapacity` instead.
    pub fn initBuffer(
        inner_x: f64,
        inner_y: f64,
        inner_radius: f64,
        outer_x: f64,
        outer_y: f64,
        outer_radius: f64,
        stops: []Stop,
        method: InterpolationMethod,
    ) Radial {
        const _inner_radius = @max(0, inner_radius);
        const _outer_radius = @max(0, outer_radius);
        // Do some pre-calculations
        const cdx = outer_x - inner_x;
        const cdy = outer_y - inner_y;
        const dr = _outer_radius - _inner_radius;
        const min_dr = -_inner_radius;
        const a = dot(f64, 3, .{ cdx, cdy, dr }, .{ cdx, cdy, -dr });
        const inv_a = if (a != 0) 1 / a else 0; // inv_a is not used if a == 0
        return .{
            .inner = .{ .x = inner_x, .y = inner_y },
            .inner_radius = _inner_radius,
            .outer = .{ .x = outer_x, .y = outer_y },
            .outer_radius = _outer_radius,
            .stops = .{
                .l = std.ArrayListUnmanaged(Stop).initBuffer(stops),
                .interpolation_method = method,
            },

            // Our pre-calcs
            .cdx = cdx,
            .cdy = cdy,
            .dr = dr,
            .min_dr = min_dr,
            .a = a,
            .inv_a = inv_a,
        };
    }

    /// Releases any stops that have been added using `Stop.List.add`. Must use
    /// the same allocator that was used there.
    pub fn deinit(self: *Radial, alloc: mem.Allocator) void {
        self.stops.deinit(alloc);
    }

    /// Returns this gradient as a higher-level gradient interface.
    pub fn asGradientInterface(self: Radial) Gradient {
        return .{ .radial = self };
    }

    /// Sets the transformation matrix for this gradient.
    ///
    /// When working with this function, keep in mind that gradients are
    /// expected to operate in _pattern space_ in the overall pattern space ->
    /// user space -> device space co-ordinate model. This effectively means
    /// that the inverse of whatever matrix is supplied here is used. If
    /// working with gradients directly and you are looking for a
    /// transformation, make sure you keep this in mind when setting the matrix
    /// (either apply the inverse or manually invert your transformations
    /// before applying them).
    ///
    /// `Context` runs this function when `Context.setPattern` is called.
    pub fn setTransformation(self: *Radial, tr: Transformation) Transformation.Error!void {
        self.transformation = try tr.inverse();
    }

    /// Gets the pixel calculated for the gradient at `(x, y)`.
    pub fn getPixel(self: *const Radial, x: i32, y: i32) pixel.Pixel {
        const search_result = self.stops.search(self.getOffset(x, y));
        return self.stops.interpolation_method.interpolateEncode(
            search_result.c0,
            search_result.c1,
            search_result.offset,
        ).asPixel();
    }

    // The radial gradient algorithm for finding t has been adapted from
    // Pixman's radial gradient algorithm
    // (https://gitlab.freedesktop.org/pixman/pixman). I've copied the notes
    // from the pertinent part of pixman-radial-gradient.c below.
    //
    // Implementation of radial gradients following the PDF specification.
    // See section 8.7.4.5.4 Type 3 (Radial) Shadings of the PDF Reference
    // Manual (PDF 32000-1:2008 at the time of this writing).
    //
    // In the radial gradient problem we are given two circles (c₁,r₁) and
    // (c₂,r₂) that define the gradient itself.
    //
    // Mathematically the gradient can be defined as the family of circles
    //
    //     ((1-t)·c₁ + t·(c₂), (1-t)·r₁ + t·r₂)
    //
    // excluding those circles whose radius would be < 0. When a point
    // belongs to more than one circle, the one with a bigger t is the only
    // one that contributes to its color. When a point does not belong
    // to any of the circles, it is transparent black, i.e. RGBA (0, 0, 0, 0).
    // Further limitations on the range of values for t are imposed when
    // the gradient is not repeated, namely t must belong to [0,1].
    //
    // The graphical result is the same as drawing the valid (radius > 0)
    // circles with increasing t in [-inf, +inf] (or in [0,1] if the gradient
    // is not repeated) using SOURCE operator composition.
    //
    // It looks like a cone pointing towards the viewer if the ending circle
    // is smaller than the starting one, a cone pointing inside the page if
    // the starting circle is the smaller one and like a cylinder if they
    // have the same radius.
    //
    // What we actually do is, given the point whose color we are interested
    // in, compute the t values for that point, solving for t in:
    //
    //     length((1-t)·c₁ + t·(c₂) - p) = (1-t)·r₁ + t·r₂
    //
    // Let's rewrite it in a simpler way, by defining some auxiliary
    // variables:
    //
    //     cd = c₂ - c₁
    //     pd = p - c₁
    //     dr = r₂ - r₁
    //     length(t·cd - pd) = r₁ + t·dr
    //
    // which actually means
    //
    //     hypot(t·cdx - pdx, t·cdy - pdy) = r₁ + t·dr
    //
    // or
    //
    //     ⎷((t·cdx - pdx)² + (t·cdy - pdy)²) = r₁ + t·dr.
    //
    // If we impose (as stated earlier) that r₁ + t·dr >= 0, it becomes:
    //
    //     (t·cdx - pdx)² + (t·cdy - pdy)² = (r₁ + t·dr)²
    //
    // where we can actually expand the squares and solve for t:
    //
    //     t²cdx² - 2t·cdx·pdx + pdx² + t²cdy² - 2t·cdy·pdy + pdy² =
    //       = r₁² + 2·r₁·t·dr + t²·dr²
    //
    //     (cdx² + cdy² - dr²)t² - 2(cdx·pdx + cdy·pdy + r₁·dr)t +
    //         (pdx² + pdy² - r₁²) = 0
    //
    //     A = cdx² + cdy² - dr²
    //     B = pdx·cdx + pdy·cdy + r₁·dr
    //     C = pdx² + pdy² - r₁²
    //     At² - 2Bt + C = 0
    //
    // The solutions (unless the equation degenerates because of A = 0) are:
    //
    //     t = (B ± ⎷(B² - A·C)) / A
    //
    // The solution we are going to prefer is the bigger one, unless the
    // radius associated to it is negative (or it falls outside the valid t
    // range).
    //
    // Additional observations (useful for optimizations):
    // A does not depend on p
    //
    // A < 0 <=> one of the two circles completely contains the other one
    //   <=> for every p, the radiuses associated with the two t solutions
    //       have opposite sign
    //
    // ---
    //
    // The following copyright notice applies to the derived code from
    // pixman-radial-gradient.c:
    //
    // Copyright © 2000 Keith Packard, member of The XFree86 Project, Inc.
    // Copyright © 2000 SuSE, Inc.
    //             2005 Lars Knoll & Zack Rusin, Trolltech
    // Copyright © 2007 Red Hat, Inc.
    //
    // Permission to use, copy, modify, distribute, and sell this software and
    // its documentation for any purpose is hereby granted without fee,
    // provided that the above copyright notice appear in all copies and that
    // both that copyright notice and this permission notice appear in
    // supporting documentation, and that the name of Keith Packard not be used
    // in advertising or publicity pertaining to distribution of the software
    // without specific, written prior permission.  Keith Packard makes no
    // representations about the suitability of this software for any purpose.
    // It is provided "as is" without express or implied warranty.
    //
    // THE COPYRIGHT HOLDERS DISCLAIM ALL WARRANTIES WITH REGARD TO THIS
    // SOFTWARE, INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND
    // FITNESS, IN NO EVENT SHALL THE COPYRIGHT HOLDERS BE LIABLE FOR ANY
    // SPECIAL, INDIRECT OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER
    // RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF
    // CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN
    // CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
    //
    // ---

    /// Calculates the offset based on the distance from the two centers of the
    /// supplied point in comparison to their radii. This offset can be used to
    /// manually search on the gradient's stops using `Stop.List.search`.
    ///
    /// ```
    /// const offset = gradient.getOffset(50, 50);
    /// const result = gradient.stops.search(offset);
    /// ... // (lerp off of search result or perform other operations)
    /// ```
    ///
    /// Negative values denote an invalid result and is valid to give to
    /// `Stop.List.search` (will return a transparent black color result).
    pub fn getOffset(self: *const Radial, x: i32, y: i32) f32 {
        // Short-circuit to invalid when both radii are zero. For some reason
        // (maybe because we don't use fixed-point like pixman?) this does not
        // return invalid correctly farther down; eventually I'd like to
        // tighten the algorithm up so that we can possibly remove this (or at
        // least be able to catch it without this).
        if (self.inner_radius == 0 and self.outer_radius == 0) return -1;

        var px: f64 = @as(f64, @floatFromInt(x)) + 0.5;
        var py: f64 = @as(f64, @floatFromInt(y)) + 0.5;
        if (!self.transformation.equal(Transformation.identity)) {
            self.transformation.userToDevice(&px, &py);
        }
        const pdx: f64 = px - self.inner.x;
        const pdy: f64 = py - self.inner.y;

        const b = dot(f64, 3, .{ pdx, pdy, self.inner_radius }, .{ self.cdx, self.cdy, self.dr });
        const c = dot(f64, 3, .{ pdx, pdy, -self.inner_radius }, .{ pdx, pdy, self.inner_radius });

        if (self.a == 0) {
            if (b == 0) {
                return -1;
            }
            // TODO: ultimately handle extend cases here (the gradient
            // technically currently repeats due to the nature of the algorithm
            const t = 0.5 * c / b;
            if (t * self.dr >= self.min_dr) {
                return @floatCast(math.clamp(t, 0, 1));
            }
            return -1;
        } else {
            const discr = dot(f64, 2, .{ b, self.a }, .{ b, -c });
            if (discr >= 0) {
                const sqrtdiscr = math.sqrt(discr);
                const t0 = (b + sqrtdiscr) * self.inv_a;
                const t1 = (b - sqrtdiscr) * self.inv_a;
                if (t0 * self.dr >= self.min_dr)
                    return @floatCast(math.clamp(t0, 0, 1))
                else if (t1 * self.dr >= self.min_dr)
                    return @floatCast(math.clamp(t1, 0, 1));
            }
        }
        return -1;
    }
};

/// Represents a conic (or "sweep") gradient, centered at a point and offset at
/// a certain point. The gradient sweeps the full circle across the stops
/// defined.
pub const Conic = struct {
    center: Point,
    angle: f64,
    transformation: Transformation = Transformation.identity,

    /// The stops contained within the gradient. Add stops using
    /// `Stop.List.add` or `Stop.List.addAssumeCapacity`.
    stops: Stop.List,

    /// Initializes the gradient with externally allocated memory for the
    /// stops. Do not use this with `deinit` or `Stop.List.add` as it will
    /// cause illegal behavior, use `Stop.List.addAssumeCapacity` instead.
    pub fn initBuffer(
        x: f64,
        y: f64,
        angle: f64,
        stops: []Stop,
        method: InterpolationMethod,
    ) Conic {
        return .{
            .center = .{ .x = x, .y = y },
            .angle = @mod(angle, math.pi * 2),
            .stops = .{
                .l = std.ArrayListUnmanaged(Stop).initBuffer(stops),
                .interpolation_method = method,
            },
        };
    }

    /// Releases any stops that have been added using `Stop.List.add`. Must use
    /// the same allocator that was used there.
    pub fn deinit(self: *Conic, alloc: mem.Allocator) void {
        self.stops.deinit(alloc);
    }

    /// Returns this gradient as a higher-level gradient interface.
    pub fn asGradientInterface(self: Conic) Gradient {
        return .{ .conic = self };
    }

    /// Sets the transformation matrix for this gradient.
    ///
    /// When working with this function, keep in mind that gradients are
    /// expected to operate in _pattern space_ in the overall pattern space ->
    /// user space -> device space co-ordinate model. This effectively means
    /// that the inverse of whatever matrix is supplied here is used. If
    /// working with gradients directly and you are looking for a
    /// transformation, make sure you keep this in mind when setting the matrix
    /// (either apply the inverse or manually invert your transformations
    /// before applying them).
    ///
    /// `Context` runs this function when `Context.setPattern` is called.
    pub fn setTransformation(self: *Conic, tr: Transformation) Transformation.Error!void {
        self.transformation = try tr.inverse();
    }

    /// Gets the pixel calculated for the gradient at `(x, y)`.
    pub fn getPixel(self: *const Conic, x: i32, y: i32) pixel.Pixel {
        const search_result = self.stops.search(self.getOffset(x, y));
        return self.stops.interpolation_method.interpolateEncode(
            search_result.c0,
            search_result.c1,
            search_result.offset,
        ).asPixel();
    }

    /// Transforms the supplied (x, y) co-ordinates into an offset based on the
    /// angular position of the point on the gradient's circle. This offset can
    /// be used to manually search on the gradient's stops using
    /// `Stop.List.search`.
    ///
    /// ```
    /// const offset = gradient.getOffset(50, 50);
    /// const result = gradient.stops.search(offset);
    /// ... // (lerp off of search result or perform other operations)
    /// ```
    pub fn getOffset(self: *const Conic, x: i32, y: i32) f32 {
        var px: f64 = @as(f64, @floatFromInt(x)) + 0.5;
        var py: f64 = @as(f64, @floatFromInt(y)) + 0.5;
        if (!self.transformation.equal(Transformation.identity)) {
            self.transformation.userToDevice(&px, &py);
        }
        const dx = px - self.center.x;
        const dy = py - self.center.y;
        const angle = @mod(math.atan2(dy, dx) - self.angle, math.pi * 2);
        return @floatCast(angle / (math.pi * 2));
    }
};

/// Represents a color stop in a gradient.
pub const Stop = struct {
    idx: usize,

    /// The color for this color stop.
    color: Color,

    /// The offset of this color stop, clamped between `0.0` and `1.0`.
    offset: f32,

    /// Represents a list of color stops. Do not copy this field directly from
    /// gradient to gradient as it may cause the index to go out of sync.
    const List = struct {
        current_idx: usize = 0,
        l: std.ArrayListUnmanaged(Stop) = .{},
        interpolation_method: InterpolationMethod,

        /// Releases any memory allocated using `add`.
        fn deinit(self: *List, alloc: mem.Allocator) void {
            self.l.deinit(alloc);
        }

        /// Adds a stop with the specified offset and color. The offset will be
        /// clamped to `0.0` and `1.0`.
        ///
        /// If stops are added at identical offsets, they will be stored in the
        /// order they were added. This can be used to define "hard stops" -
        /// parts of gradients that transition from one color to another
        /// directly without interpolation.
        ///
        /// Note that hard stops are not anti-aliased. To achieve a similar
        /// smoothing effect, one can add a slightly small offset to one side
        /// of the hard stop to produce a small amount of interpolation:
        ///
        /// ```
        /// try gradient.stops.add(alloc, 0,   .{ .rgb = .{ 1, 0, 0 } });
        /// try gradient.stops.add(alloc, 0.5, .{ .rgb = .{ 1, 0, 0 } });
        /// try gradient.stops.add(alloc, 0.501, .{ .rgb = .{ 0, 1, 0 } });
        /// try gradient.stops.add(alloc, 1,   .{ .rgb = .{ 0, 1, 0 } });
        /// ```
        pub fn add(
            self: *List,
            alloc: mem.Allocator,
            offset: f32,
            color: Color.InitArgs,
        ) mem.Allocator.Error!void {
            const newlen = self.l.items.len + 1;
            try self.l.ensureTotalCapacity(alloc, newlen);
            self.addAssumeCapacity(offset, color);
        }

        /// Like `add`, but assumes the list can hold the stop.
        pub fn addAssumeCapacity(self: *List, offset: f32, color: Color.InitArgs) void {
            const _offset = math.clamp(offset, 0, 1);
            self.l.appendAssumeCapacity(.{
                .idx = self.current_idx,
                .color = Color.init(color),
                .offset = _offset,
            });
            mem.sort(Stop, self.l.items, {}, stop_sort_asc);
            self.current_idx += 1;
        }

        fn stop_sort_asc(_: void, a: Stop, b: Stop) bool {
            if (a.offset == b.offset) return a.idx < b.idx;
            return a.offset < b.offset;
        }

        /// Represents a color stop search result.
        ///
        /// The offset given within the result is the relative offset (the
        /// distance between the two stops), versus the absolute offset given
        /// to `search`.
        pub const SearchResult = struct {
            c0: Color,
            c1: Color,
            offset: f32,
        };

        /// Returns a start color, an end color, and a relative offset within
        /// the stop list, suitable for linear interpolation.
        ///
        /// Offset is clamped to `0.0` and `1.0`, with the exception of
        /// negative values (our way to denote an invalid t result from
        /// `getOffset` calls) which return transparent black.
        ///
        /// The result of an empty list is also transparent black.
        pub fn search(self: *const List, offset: f32) SearchResult {
            if (offset < 0 or self.l.items.len == 0) return .{
                .c0 = colorpkg.LinearRGB.init(0, 0, 0, 0).asColor(),
                .c1 = colorpkg.LinearRGB.init(0, 0, 0, 0).asColor(),
                .offset = 0,
            };
            const _offset = @min(offset, 1);
            // Binary search, testing for a relative start/end that will
            // contain our offset. This was adapted from stdlib and updated to
            // be a bit more "fuzzy" as obviously we need an approximate match,
            // not an exact one.
            var left: usize = 0;
            var right: usize = self.l.items.len;
            var mid: usize = undefined;

            while (left < right) {
                // Avoid overflowing in the midpoint calculation
                mid = left + (right - left) / 2;

                // Check to see if we're inbetween mid and mid + 1
                if (_offset >= self.l.items[mid].offset and
                    (mid == self.l.items.len - 1 or _offset <= self.l.items[mid + 1].offset))
                {
                    break;
                }

                // Compare the key with the midpoint element
                if (_offset < self.l.items[mid].offset) {
                    right = mid;
                    continue;
                }

                if (_offset > self.l.items[mid].offset) {
                    left = mid + 1;
                    continue;
                }
            }

            if (mid == self.l.items.len - 1) {
                // We're beyond the last stop
                return .{
                    .c0 = self.l.items[mid].color,
                    .c1 = self.l.items[mid].color,
                    .offset = _offset - self.l.items[mid].offset,
                };
            }

            if (mid == 0 and _offset < self.l.items[mid].offset) {
                // We're before the first stop
                return .{
                    .c0 = self.l.items[mid].color,
                    .c1 = self.l.items[mid].color,
                    .offset = _offset / self.l.items[mid].offset,
                };
            }

            const start = self.l.items[mid].offset;
            const end = self.l.items[mid + 1].offset;
            const relative_len = end - start;
            const relative_offset = if (relative_len != 0) (_offset - start) / relative_len else 0;
            return .{
                .c0 = self.l.items[mid].color,
                .c1 = self.l.items[mid + 1].color,
                .offset = relative_offset,
            };
        }
    };
};

fn sq(x: anytype) @TypeOf(x) {
    return x * x;
}

fn dotSq(x: anytype, y: anytype) @TypeOf(x, y) {
    return dot(@TypeOf(x, y), 2, .{ x, y }, .{ x, y });
}

fn dot(comptime T: type, comptime len: usize, a: [len]T, b: [len]T) T {
    var result: T = 0;
    for (0..len) |i| result += a[i] * b[i];
    return result;
}

test "Stop.List.addAssumeCapacity" {
    var stops: [7]Stop = undefined;
    var stop_list: Stop.List = .{
        .l = std.ArrayListUnmanaged(Stop).initBuffer(&stops),
        .interpolation_method = .linear_rgb,
    };
    stop_list.addAssumeCapacity(0.75, .{ .rgb = .{ 1, 0, 0 } });
    stop_list.addAssumeCapacity(0.25, .{ .rgb = .{ 0, 1, 0 } });
    stop_list.addAssumeCapacity(0.9, .{ .rgb = .{ 0, 0, 1 } });
    stop_list.addAssumeCapacity(0.5, .{ .hsl = .{ 300, 1, 0.5 } });

    const expected = [_]Stop{
        .{ .idx = 1, .color = colorpkg.LinearRGB.init(0, 1, 0, 1).asColor(), .offset = 0.25 },
        .{ .idx = 3, .color = colorpkg.HSL.init(300, 1, 0.5, 1).asColor(), .offset = 0.5 },
        .{ .idx = 0, .color = colorpkg.LinearRGB.init(1, 0, 0, 1).asColor(), .offset = 0.75 },
        .{ .idx = 2, .color = colorpkg.LinearRGB.init(0, 0, 1, 1).asColor(), .offset = 0.9 },
    };
    try testing.expectEqualDeep(&expected, stop_list.l.items);

    // clamped
    stop_list.addAssumeCapacity(-1.0, .{ .srgb = .{ 1, 0, 0 } });
    stop_list.addAssumeCapacity(2.0, .{ .srgb = .{ 0, 1, 0 } });

    const expected_clamped = [_]Stop{
        .{ .idx = 4, .color = colorpkg.SRGB.init(1, 0, 0, 1).asColor(), .offset = 0.0 },
        .{ .idx = 1, .color = colorpkg.LinearRGB.init(0, 1, 0, 1).asColor(), .offset = 0.25 },
        .{ .idx = 3, .color = colorpkg.HSL.init(300, 1, 0.5, 1).asColor(), .offset = 0.5 },
        .{ .idx = 0, .color = colorpkg.LinearRGB.init(1, 0, 0, 1).asColor(), .offset = 0.75 },
        .{ .idx = 2, .color = colorpkg.LinearRGB.init(0, 0, 1, 1).asColor(), .offset = 0.9 },
        .{ .idx = 5, .color = colorpkg.SRGB.init(0, 1, 0, 1).asColor(), .offset = 1.0 },
    };
    try testing.expectEqualDeep(&expected_clamped, stop_list.l.items);

    // identical offset
    stop_list.addAssumeCapacity(0.25, .{ .hsl = .{ 130, 0.9, 0.45 } });

    const expected_identical_offset = [_]Stop{
        .{ .idx = 4, .color = colorpkg.SRGB.init(1, 0, 0, 1).asColor(), .offset = 0.0 },
        .{ .idx = 1, .color = colorpkg.LinearRGB.init(0, 1, 0, 1).asColor(), .offset = 0.25 },
        .{ .idx = 6, .color = colorpkg.HSL.init(130, 0.9, 0.45, 1).asColor(), .offset = 0.25 },
        .{ .idx = 3, .color = colorpkg.HSL.init(300, 1, 0.5, 1).asColor(), .offset = 0.5 },
        .{ .idx = 0, .color = colorpkg.LinearRGB.init(1, 0, 0, 1).asColor(), .offset = 0.75 },
        .{ .idx = 2, .color = colorpkg.LinearRGB.init(0, 0, 1, 1).asColor(), .offset = 0.9 },
        .{ .idx = 5, .color = colorpkg.SRGB.init(0, 1, 0, 1).asColor(), .offset = 1.0 },
    };
    try testing.expectEqualDeep(&expected_identical_offset, stop_list.l.items);
}

test "Stop.List.search" {
    // Zero elements
    var stop_list_zero: Stop.List = .{
        .interpolation_method = .linear_rgb,
    };
    try testing.expectEqualDeep(Stop.List.SearchResult{
        .c0 = colorpkg.LinearRGB.init(0, 0, 0, 0).asColor(),
        .c1 = colorpkg.LinearRGB.init(0, 0, 0, 0).asColor(),
        .offset = 0,
    }, stop_list_zero.search(0.5));

    // Actual tests
    var stops: [5]Stop = undefined;
    var stop_list: Stop.List = .{
        .l = std.ArrayListUnmanaged(Stop).initBuffer(&stops),
        .interpolation_method = .linear_rgb,
    };

    stop_list.addAssumeCapacity(0.25, .{ .rgb = .{ 1, 0, 0 } });
    stop_list.addAssumeCapacity(0.5, .{ .rgb = .{ 0, 1, 0 } });
    stop_list.addAssumeCapacity(0.75, .{ .rgb = .{ 0, 0, 1 } });
    stop_list.addAssumeCapacity(0.9, .{ .hsl = .{ 300, 1, 0.5 } });

    // basic
    var got = stop_list.search(0.6);
    var expected: Stop.List.SearchResult = .{
        .c0 = colorpkg.LinearRGB.init(0, 1, 0, 1).asColor(),
        .c1 = colorpkg.LinearRGB.init(0, 0, 1, 1).asColor(),
        .offset = 0.4,
    };
    try testing.expectEqualDeep(expected.c0, got.c0);
    try testing.expectEqualDeep(expected.c1, got.c1);
    try testing.expectApproxEqAbs(expected.offset, got.offset, math.floatEps(f32));

    // smaller interval
    got = stop_list.search(0.85);
    expected = .{
        .c0 = colorpkg.LinearRGB.init(0, 0, 1, 1).asColor(),
        .c1 = colorpkg.HSL.init(300, 1, 0.5, 1).asColor(),
        .offset = 2.0 / 3.0 + math.floatEps(f32), // (rofl, in testing, this is the smallest fraction off of epsilon)
    };
    try testing.expectEqualDeep(expected.c0, got.c0);
    try testing.expectEqualDeep(expected.c1, got.c1);
    try testing.expectApproxEqAbs(expected.offset, got.offset, math.floatEps(f32));

    // start
    got = stop_list.search(0.1);
    expected = .{
        .c0 = colorpkg.LinearRGB.init(1, 0, 0, 1).asColor(),
        .c1 = colorpkg.LinearRGB.init(1, 0, 0, 1).asColor(),
        .offset = 0.4,
    };
    try testing.expectEqualDeep(expected.c0, got.c0);
    try testing.expectEqualDeep(expected.c1, got.c1);
    try testing.expectApproxEqAbs(expected.offset, got.offset, math.floatEps(f32));

    // end
    got = stop_list.search(0.95);
    expected = .{
        .c0 = colorpkg.HSL.init(300, 1, 0.5, 1).asColor(),
        .c1 = colorpkg.HSL.init(300, 1, 0.5, 1).asColor(),
        .offset = 0.05,
    };
    try testing.expectEqualDeep(expected.c0, got.c0);
    try testing.expectEqualDeep(expected.c1, got.c1);
    try testing.expectApproxEqAbs(expected.offset, got.offset, math.floatEps(f32));

    // exactly 0
    got = stop_list.search(0.0);
    expected = .{
        .c0 = colorpkg.LinearRGB.init(1, 0, 0, 1).asColor(),
        .c1 = colorpkg.LinearRGB.init(1, 0, 0, 1).asColor(),
        .offset = 0.0,
    };
    try testing.expectEqualDeep(expected.c0, got.c0);
    try testing.expectEqualDeep(expected.c1, got.c1);
    try testing.expectApproxEqAbs(expected.offset, got.offset, math.floatEps(f32));

    // exactly 1
    got = stop_list.search(1.0);
    expected = .{
        .c0 = colorpkg.HSL.init(300, 1, 0.5, 1).asColor(),
        .c1 = colorpkg.HSL.init(300, 1, 0.5, 1).asColor(),
        .offset = 0.1,
    };
    try testing.expectEqualDeep(expected.c0, got.c0);
    try testing.expectEqualDeep(expected.c1, got.c1);
    try testing.expectApproxEqAbs(expected.offset, got.offset, math.floatEps(f32));

    // exact on stop
    got = stop_list.search(0.25);
    expected = .{
        .c0 = colorpkg.LinearRGB.init(1, 0, 0, 1).asColor(),
        .c1 = colorpkg.LinearRGB.init(0, 1, 0, 1).asColor(),
        .offset = 0.0,
    };
    try testing.expectEqualDeep(expected.c0, got.c0);
    try testing.expectEqualDeep(expected.c1, got.c1);
    try testing.expectApproxEqAbs(expected.offset, got.offset, math.floatEps(f32));

    // clamped ( < 0)
    got = stop_list.search(-1.0);
    expected = .{
        .c0 = colorpkg.LinearRGB.init(0, 0, 0, 0).asColor(),
        .c1 = colorpkg.LinearRGB.init(0, 0, 0, 0).asColor(),
        .offset = 0.0,
    };
    try testing.expectEqualDeep(expected.c0, got.c0);
    try testing.expectEqualDeep(expected.c1, got.c1);
    try testing.expectApproxEqAbs(expected.offset, got.offset, math.floatEps(f32));

    // clamped ( > 1)
    got = stop_list.search(2.0);
    expected = .{
        .c0 = colorpkg.HSL.init(300, 1, 0.5, 1).asColor(),
        .c1 = colorpkg.HSL.init(300, 1, 0.5, 1).asColor(),
        .offset = 0.1,
    };
    try testing.expectEqualDeep(expected.c0, got.c0);
    try testing.expectEqualDeep(expected.c1, got.c1);
    try testing.expectApproxEqAbs(expected.offset, got.offset, math.floatEps(f32));

    // Double offset
    stop_list.addAssumeCapacity(0.25, .{ .hsl = .{ 130, 0.9, 0.45 } });
    got = stop_list.search(0.25);
    expected = .{
        .c0 = colorpkg.HSL.init(130, 0.9, 0.45, 1).asColor(),
        .c1 = colorpkg.LinearRGB.init(0, 1, 0, 1).asColor(),
        .offset = 0.0,
    };
    try testing.expectEqualDeep(expected.c0, got.c0);
    try testing.expectEqualDeep(expected.c1, got.c1);
    try testing.expectApproxEqAbs(expected.offset, got.offset, math.floatEps(f32));
}

test "Stop.List.search, hard stops" {
    var stop_buffer: [6]Stop = undefined;
    var stops: Stop.List = .{
        .l = std.ArrayListUnmanaged(Stop).initBuffer(&stop_buffer),
        .interpolation_method = .linear_rgb,
    };
    stops.addAssumeCapacity(0, .{ .rgb = .{ 1, 0, 0 } });
    stops.addAssumeCapacity(1.0 / 3.0, .{ .rgb = .{ 1, 0, 0 } });
    stops.addAssumeCapacity(1.0 / 3.0, .{ .rgb = .{ 0, 1, 0 } });
    stops.addAssumeCapacity(2.0 / 3.0, .{ .rgb = .{ 0, 1, 0 } });
    stops.addAssumeCapacity(2.0 / 3.0, .{ .rgb = .{ 0, 0, 1 } });
    stops.addAssumeCapacity(1, .{ .rgb = .{ 0, 0, 1 } });

    try testing.expectEqualDeep(Stop.List.SearchResult{
        .c0 = colorpkg.LinearRGB.init(1, 0, 0, 1).asColor(),
        .c1 = colorpkg.LinearRGB.init(1, 0, 0, 1).asColor(),
        .offset = 0.0,
    }, stops.search(0));
    try testing.expectEqualDeep(Stop.List.SearchResult{
        .c0 = colorpkg.LinearRGB.init(1, 0, 0, 1).asColor(),
        .c1 = colorpkg.LinearRGB.init(1, 0, 0, 1).asColor(),
        .offset = 0.5,
    }, stops.search(1.0 / 6.0));
    try testing.expectEqualDeep(Stop.List.SearchResult{
        .c0 = colorpkg.LinearRGB.init(1, 0, 0, 1).asColor(),
        .c1 = colorpkg.LinearRGB.init(0, 1, 0, 1).asColor(),
        .offset = 0.0,
    }, stops.search(1.0 / 3.0));
    try testing.expectEqualDeep(Stop.List.SearchResult{
        .c0 = colorpkg.LinearRGB.init(0, 1, 0, 1).asColor(),
        .c1 = colorpkg.LinearRGB.init(0, 1, 0, 1).asColor(),
        .offset = 0.49999997,
    }, stops.search(0.5));
    try testing.expectEqualDeep(Stop.List.SearchResult{
        .c0 = colorpkg.LinearRGB.init(0, 1, 0, 1).asColor(),
        .c1 = colorpkg.LinearRGB.init(0, 0, 1, 1).asColor(),
        .offset = 0.0,
    }, stops.search(2.0 / 3.0));
    try testing.expectEqualDeep(Stop.List.SearchResult{
        .c0 = colorpkg.LinearRGB.init(0, 0, 1, 1).asColor(),
        .c1 = colorpkg.LinearRGB.init(0, 0, 1, 1).asColor(),
        .offset = 0.4999999,
    }, stops.search(5.0 / 6.0));
    try testing.expectEqualDeep(Stop.List.SearchResult{
        .c0 = colorpkg.LinearRGB.init(0, 0, 1, 1).asColor(),
        .c1 = colorpkg.LinearRGB.init(0, 0, 1, 1).asColor(),
        .offset = 0,
    }, stops.search(1));
}

test "Linear.initBuffer" {
    const name = "Linear.initBuffer";
    var buf = [_]Stop{
        .{
            .idx = 0,
            .color = Color.init(.{ .rgb = .{ 1, 0, 0 } }),
            .offset = 0.5,
        },
    };
    const cases = [_]struct {
        name: []const u8,
        expected: Linear,
        x0: f64,
        y0: f64,
        x1: f64,
        y1: f64,
        buffer: []Stop,
        method: InterpolationMethod,
    }{
        .{
            .name = "basic",
            .expected = .{
                .start = .{ .x = 0, .y = 0 },
                .end = .{ .x = 99, .y = 99 },
                .stops = .{
                    .l = std.ArrayListUnmanaged(Stop).initBuffer(&buf),
                    .interpolation_method = .linear_rgb,
                },
            },
            .x0 = 0,
            .y0 = 0,
            .x1 = 99,
            .y1 = 99,
            .buffer = &buf,
            .method = .linear_rgb,
        },
    };
    const TestFn = struct {
        fn f(tc: anytype) TestingError!void {
            try testing.expectEqualDeep(tc.expected, Linear.initBuffer(
                tc.x0,
                tc.y0,
                tc.x1,
                tc.y1,
                tc.buffer,
                tc.method,
            ));
        }
    };
    try runCases(name, cases, TestFn.f);
}

test "Linear.getOffset" {
    const name = "Linear.getOffset";
    const cases = [_]struct {
        name: []const u8,
        expected: f32,
        x0: f64,
        y0: f64,
        x1: f64,
        y1: f64,
        matrix: Transformation = Transformation.identity,
        x: i32,
        y: i32,
    }{
        .{
            .name = "basic",
            .expected = 0.5,
            .x0 = 0,
            .y0 = 0,
            .x1 = 49,
            .y1 = 49,
            .x = 24,
            .y = 24,
        },
        .{
            .name = "with matrix",
            .expected = 0.24872449,
            .x0 = 0,
            .y0 = 0,
            .x1 = 49,
            .y1 = 49,
            .matrix = Transformation.identity.scale(2, 4),
            .x = 24,
            .y = 48,
        },
    };
    const TestFn = struct {
        fn f(tc: anytype) TestingError!void {
            var gradient = Linear.initBuffer(
                tc.x0,
                tc.y0,
                tc.x1,
                tc.y1,
                &[_]Stop{},
                .linear_rgb,
            );
            try gradient.setTransformation(tc.matrix);
            try testing.expectEqual(tc.expected, gradient.getOffset(tc.x, tc.y));
        }
    };
    try runCases(name, cases, TestFn.f);
}

test "Linear.getPixel" {
    {
        var stop_buffer: [3]Stop = undefined;
        var gradient = Linear.initBuffer(0, 0, 99, 99, &stop_buffer, .linear_rgb);
        gradient.stops.addAssumeCapacity(0, .{ .rgb = .{ 1, 0, 0 } });
        gradient.stops.addAssumeCapacity(0.5, .{ .rgb = .{ 0, 1, 0 } });
        gradient.stops.addAssumeCapacity(1, .{ .rgb = .{ 0, 0, 1 } });

        // Basic test along the gradient line, pretty much zero projection. You get
        // to see the rounding fun that happens though with some of the midpoints.
        // This is fine.

        // NOTE: Since we start in the middle of the pixel, (0,0) is not
        // exactly on the edge of the gradient. We test (-1, -1) to get that.
        try testing.expectEqualDeep(pixel.Pixel{ .rgba = .{
            .r = 255,
            .g = 0,
            .b = 0,
            .a = 255,
        } }, gradient.getPixel(-1, -1));
        try testing.expectEqualDeep(pixel.Pixel{
            .rgba = .{
                .r = 252, // (0, 0) is technically (0.5, 0.5)
                .g = 3,
                .b = 0,
                .a = 255,
            },
        }, gradient.getPixel(0, 0));
        try testing.expectEqualDeep(pixel.Pixel{ .rgba = .{
            .r = 124,
            .g = 131,
            .b = 0,
            .a = 255,
        } }, gradient.getPixel(25, 25));
        try testing.expectEqualDeep(pixel.Pixel{ .rgba = .{
            .r = 0,
            .g = 255,
            .b = 0,
            .a = 255,
        } }, gradient.getPixel(49, 49));
        try testing.expectEqualDeep(pixel.Pixel{ .rgba = .{
            .r = 0,
            .g = 126,
            .b = 129,
            .a = 255,
        } }, gradient.getPixel(74, 74));
        try testing.expectEqualDeep(pixel.Pixel{ .rgba = .{
            .r = 0,
            .g = 0,
            .b = 255,
            .a = 255,
        } }, gradient.getPixel(99, 99));

        // Projection tests, to show the effect of orthogonal projection for pixels
        // not exactly on the gradient line (pretty much all pixels, really).
        try testing.expectEqualDeep(pixel.Pixel{ .rgba = .{
            .r = 126,
            .g = 129,
            .b = 0,
            .a = 255,
        } }, gradient.getPixel(49, 0));
        try testing.expectEqualDeep(pixel.Pixel{ .rgba = .{
            .r = 0,
            .g = 252,
            .b = 3,
            .a = 255,
        } }, gradient.getPixel(0, 99));
        try testing.expectEqualDeep(pixel.Pixel{ .rgba = .{
            .r = 0,
            .g = 124,
            .b = 131,
            .a = 255,
        } }, gradient.getPixel(149, 0));
        try testing.expectEqualDeep(pixel.Pixel{ .rgba = .{
            .r = 0,
            .g = 0,
            .b = 255,
            .a = 255,
        } }, gradient.getPixel(0, 199));
    }

    {
        // HSL along the short path
        var stop_buffer: [2]Stop = undefined;
        var gradient = Linear.initBuffer(0, 0, 99, 99, &stop_buffer, .{ .hsl = .shorter });
        gradient.stops.addAssumeCapacity(0, .{ .hsl = .{ 300, 1, 0.5 } });
        gradient.stops.addAssumeCapacity(1, .{ .hsl = .{ 50, 1, 0.5 } });

        try testing.expectEqualDeep(pixel.Pixel{ .rgba = .{
            .r = 255,
            .g = 0,
            .b = 255,
            .a = 255,
        } }, gradient.getPixel(-1, -1));
        try testing.expectEqualDeep(pixel.Pixel{ .rgba = .{
            .r = 255,
            .g = 0,
            .b = 139,
            .a = 255,
        } }, gradient.getPixel(24, 24));
        try testing.expectEqualDeep(pixel.Pixel{ .rgba = .{
            .r = 255,
            .g = 0,
            .b = 21,
            .a = 255,
        } }, gradient.getPixel(49, 49));
        try testing.expectEqualDeep(pixel.Pixel{ .rgba = .{
            .r = 255,
            .g = 97,
            .b = 0,
            .a = 255,
        } }, gradient.getPixel(74, 74));
        try testing.expectEqualDeep(pixel.Pixel{ .rgba = .{
            .r = 255,
            .g = 213,
            .b = 0,
            .a = 255,
        } }, gradient.getPixel(99, 99));
    }
}

test "Radial.getOffset" {
    const name = "Radial.getOffset";
    const cases = [_]struct {
        name: []const u8,
        expected: f32,
        inner_x: f64,
        inner_y: f64,
        inner_radius: f64,
        outer_x: f64,
        outer_y: f64,
        outer_radius: f64,
        interpolation_method: InterpolationMethod,
        matrix: Transformation = Transformation.identity,
        x: i32,
        y: i32,
    }{
        .{
            .name = "basic",
            .expected = 0.7212489,
            .inner_x = 49,
            .inner_y = 49,
            .inner_radius = 0,
            .outer_x = 49,
            .outer_y = 49,
            .outer_radius = 50,
            .interpolation_method = .linear_rgb,
            .x = 74,
            .y = 74,
        },
        .{
            .name = "basic on x or y axis",
            .expected = 0.51009804,
            .inner_x = 49,
            .inner_y = 49,
            .inner_radius = 0,
            .outer_x = 49,
            .outer_y = 49,
            .outer_radius = 50,
            .interpolation_method = .linear_rgb,
            .x = 49,
            .y = 74,
        },
        .{
            .name = "zero radius",
            .expected = -1,
            .inner_x = 24,
            .inner_y = 24,
            .inner_radius = 0,
            .outer_x = 49,
            .outer_y = 49,
            .outer_radius = 0,
            .interpolation_method = .linear_rgb,
            .x = 74,
            .y = 74,
        },
        .{
            .name = "off-center, longer side",
            .expected = 0.82655096,
            .inner_x = 24,
            .inner_y = 24,
            .inner_radius = 5,
            .outer_x = 49,
            .outer_y = 49,
            .outer_radius = 50,
            .interpolation_method = .linear_rgb,
            .x = 74,
            .y = 74,
        },
        .{
            .name = "off-center, shorter side",
            .expected = 0.14142136,
            .inner_x = 24,
            .inner_y = 24,
            .inner_radius = 5,
            .outer_x = 49,
            .outer_y = 49,
            .outer_radius = 50,
            .interpolation_method = .linear_rgb,
            .x = 19,
            .y = 19,
        },
        .{
            .name = "with matrix",
            .expected = 0.7124123,
            .inner_x = 49,
            .inner_y = 49,
            .inner_radius = 0,
            .outer_x = 49,
            .outer_y = 49,
            .outer_radius = 50,
            .interpolation_method = .linear_rgb,
            .matrix = Transformation.identity.scale(2, 4),
            .x = 148,
            .y = 296,
        },
    };
    const TestFn = struct {
        fn f(tc: anytype) TestingError!void {
            var gradient = Radial.initBuffer(
                tc.inner_x,
                tc.inner_y,
                tc.inner_radius,
                tc.outer_x,
                tc.outer_y,
                tc.outer_radius,
                &[_]Stop{},
                tc.interpolation_method,
            );
            try gradient.setTransformation(tc.matrix);
            try testing.expectEqual(tc.expected, gradient.getOffset(tc.x, tc.y));
        }
    };
    try runCases(name, cases, TestFn.f);
}

test "Radial.initBuffer" {
    const name = "Radial.initBuffer";
    var buf = [_]Stop{
        .{
            .idx = 0,
            .color = Color.init(.{ .rgb = .{ 1, 0, 0 } }),
            .offset = 0.5,
        },
    };
    const cases = [_]struct {
        name: []const u8,
        expected: Radial,
        outer_x: f64,
        outer_y: f64,
        outer_radius: f64,
        inner_x: f64,
        inner_y: f64,
        inner_radius: f64,
        buffer: []Stop,
        method: InterpolationMethod,
    }{
        .{
            .name = "basic",
            .expected = .{
                .inner = .{ .x = 24, .y = 25 },
                .inner_radius = 26,
                .outer = .{ .x = 49, .y = 50 },
                .outer_radius = 51,
                .stops = .{
                    .l = std.ArrayListUnmanaged(Stop).initBuffer(&buf),
                    .interpolation_method = .linear_rgb,
                },
                .cdx = 25,
                .cdy = 25,
                .dr = 25,
                .min_dr = -26,
                .a = 625,
                .inv_a = 0.0016,
            },
            .inner_x = 24,
            .inner_y = 25,
            .inner_radius = 26,
            .outer_x = 49,
            .outer_y = 50,
            .outer_radius = 51,
            .buffer = &buf,
            .method = .linear_rgb,
        },
        .{
            .name = "below zero radii",
            .expected = .{
                .inner = .{ .x = 24, .y = 25 },
                .inner_radius = 0,
                .outer = .{ .x = 49, .y = 50 },
                .outer_radius = 0,
                .stops = .{
                    .l = std.ArrayListUnmanaged(Stop).initBuffer(&buf),
                    .interpolation_method = .linear_rgb,
                },
                .cdx = 25,
                .cdy = 25,
                .dr = 0,
                .min_dr = -0.0,
                .a = 1250,
                .inv_a = 0.0008,
            },
            .inner_x = 24,
            .inner_y = 25,
            .inner_radius = -1,
            .outer_x = 49,
            .outer_y = 50,
            .outer_radius = -1,
            .buffer = &buf,
            .method = .linear_rgb,
        },
        .{
            .name = "degenerate points (a == 0)",
            .expected = .{
                .inner = .{ .x = 0, .y = 0 },
                .inner_radius = 0,
                .outer = .{ .x = 0, .y = 50 },
                .outer_radius = 50,
                .stops = .{
                    .l = std.ArrayListUnmanaged(Stop).initBuffer(&buf),
                    .interpolation_method = .linear_rgb,
                },
                .cdx = 0,
                .cdy = 50,
                .dr = 50,
                .min_dr = -0.0,
                .a = 0,
                .inv_a = 0,
            },
            .inner_x = 0,
            .inner_y = 0,
            .inner_radius = 0,
            .outer_x = 0,
            .outer_y = 50,
            .outer_radius = 50,
            .buffer = &buf,
            .method = .linear_rgb,
        },
    };
    const TestFn = struct {
        fn f(tc: anytype) TestingError!void {
            try testing.expectEqualDeep(tc.expected, Radial.initBuffer(
                tc.inner_x,
                tc.inner_y,
                tc.inner_radius,
                tc.outer_x,
                tc.outer_y,
                tc.outer_radius,
                tc.buffer,
                tc.method,
            ));
        }
    };
    try runCases(name, cases, TestFn.f);
}

test "Radial.getPixel" {
    var stop_buffer: [2]Stop = undefined;
    var gradient = Radial.initBuffer(49, 49, 0, 49, 49, 50, &stop_buffer, .linear_rgb);
    gradient.stops.addAssumeCapacity(0, .{ .rgb = .{ 1, 0, 0 } });
    gradient.stops.addAssumeCapacity(1, .{ .rgb = .{ 0, 1, 0 } });
    try testing.expectEqualDeep(pixel.Pixel{ .rgba = .{
        .r = 125,
        .g = 130,
        .b = 0,
        .a = 255,
    } }, gradient.getPixel(49, 74));
}

test "Conic.initBuffer" {
    const name = "Conic.initBuffer";
    var buf = [_]Stop{
        .{
            .idx = 0,
            .color = Color.init(.{ .rgb = .{ 1, 0, 0 } }),
            .offset = 0.5,
        },
    };
    const cases = [_]struct {
        name: []const u8,
        expected: Conic,
        x: f64,
        y: f64,
        angle: f64,
        buffer: []Stop,
        method: InterpolationMethod,
    }{
        .{
            .name = "basic",
            .expected = .{
                .center = .{ .x = 49, .y = 49 },
                .angle = math.pi / 4.0,
                .stops = .{
                    .l = std.ArrayListUnmanaged(Stop).initBuffer(&buf),
                    .interpolation_method = .linear_rgb,
                },
            },
            .x = 49,
            .y = 49,
            .angle = math.pi / 4.0,
            .buffer = &buf,
            .method = .linear_rgb,
        },
        .{
            .name = "angle over 2 x pi",
            .expected = .{
                .center = .{ .x = 49, .y = 49 },
                .angle = math.pi * 0.5,
                .stops = .{
                    .l = std.ArrayListUnmanaged(Stop).initBuffer(&buf),
                    .interpolation_method = .linear_rgb,
                },
            },
            .x = 49,
            .y = 49,
            .angle = math.pi * 2.5,
            .buffer = &buf,
            .method = .linear_rgb,
        },
        .{
            .name = "negative angle",
            .expected = .{
                .center = .{ .x = 49, .y = 49 },
                .angle = math.pi * 1.5,
                .stops = .{
                    .l = std.ArrayListUnmanaged(Stop).initBuffer(&buf),
                    .interpolation_method = .linear_rgb,
                },
            },
            .x = 49,
            .y = 49,
            .angle = math.pi * -0.5,
            .buffer = &buf,
            .method = .linear_rgb,
        },
    };
    const TestFn = struct {
        fn f(tc: anytype) TestingError!void {
            try testing.expectEqualDeep(tc.expected, Conic.initBuffer(
                tc.x,
                tc.y,
                tc.angle,
                tc.buffer,
                tc.method,
            ));
        }
    };
    try runCases(name, cases, TestFn.f);
}

test "Conic.getOffset" {
    const name = "Conic.getOffset";
    const cases = [_]struct {
        name: []const u8,
        expected: f32,
        center_x: f64,
        center_y: f64,
        angle: f64,
        matrix: Transformation = Transformation.identity,
        x: i32,
        y: i32,
    }{
        .{
            .name = "basic",
            .expected = 0.25,
            .center_x = 49.5,
            .center_y = 49,
            .angle = 0,
            .x = 49,
            .y = 99,
        },
        .{
            .name = "relative start",
            .expected = 0.125,
            .center_x = 49.5,
            .center_y = 49,
            .angle = math.pi / 4.0,
            .x = 49,
            .y = 99,
        },
        .{
            .name = "relative ccw from start",
            .expected = 0.875,
            .center_x = 49,
            .center_y = 49.5,
            .angle = math.pi / 4.0,
            .x = 99,
            .y = 49,
        },
        .{
            .name = "with matrix",
            .expected = 0.25079378,
            .center_x = 49.5,
            .center_y = 49,
            .angle = 0,
            .matrix = Transformation.identity.scale(2, 4),
            .x = 98,
            .y = 396,
        },
    };
    const TestFn = struct {
        fn f(tc: anytype) TestingError!void {
            var gradient = Conic.initBuffer(
                tc.center_x,
                tc.center_y,
                tc.angle,
                &[_]Stop{},
                .linear_rgb,
            );
            try gradient.setTransformation(tc.matrix);
            try testing.expectEqual(tc.expected, gradient.getOffset(tc.x, tc.y));
        }
    };
    try runCases(name, cases, TestFn.f);
}

test "Conic.getPixel" {
    var stop_buffer: [2]Stop = undefined;
    var gradient = Conic.initBuffer(49, 49.5, 0, &stop_buffer, .linear_rgb);
    gradient.stops.addAssumeCapacity(0, .{ .rgb = .{ 1, 0, 0 } });
    gradient.stops.addAssumeCapacity(1, .{ .rgb = .{ 0, 1, 0 } });
    try testing.expectEqualDeep(pixel.Pixel{ .rgba = .{
        .r = 128,
        .g = 128,
        .b = 0,
        .a = 255,
    } }, gradient.getPixel(0, 49));
}

test "Linear.setTransformation" {
    const matrix = Transformation.identity.scale(2, 3);
    var gradient = Linear.initBuffer(1, 1, 10, 10, &[_]Stop{}, .linear_rgb);
    try gradient.setTransformation(matrix);
    try testing.expectEqualDeep(Linear{
        .start = .{ .x = 1, .y = 1 },
        .end = .{ .x = 10, .y = 10 },
        .transformation = try matrix.inverse(),
        .stops = .{
            .interpolation_method = .linear_rgb,
        },
    }, gradient);
}

test "Gradient interface" {
    const name = "Gradient interface";
    const cases = [_]struct {
        name: []const u8,
        args: Gradient.InitArgs,
        expected: Gradient,
    }{
        .{
            .name = "linear",
            .args = .{
                .type = .{ .linear = .{
                    .x0 = 0,
                    .y0 = 0,
                    .x1 = 99,
                    .y1 = 99,
                } },
            },
            .expected = .{
                .linear = Linear.initBuffer(0, 0, 99, 99, &[_]Stop{}, .linear_rgb),
            },
        },
        .{
            .name = "radial",
            .args = .{
                .type = .{ .radial = .{
                    .inner_x = 100,
                    .inner_y = 100,
                    .inner_radius = 0,
                    .outer_x = 150,
                    .outer_y = 150,
                    .outer_radius = 100,
                } },
            },
            .expected = .{
                .radial = Radial.initBuffer(100, 100, 0, 150, 150, 100, &[_]Stop{}, .linear_rgb),
            },
        },
        .{
            .name = "conic",
            .args = .{
                .type = .{ .conic = .{
                    .x = 100,
                    .y = 150,
                    .angle = 45,
                } },
            },
            .expected = .{
                .conic = Conic.initBuffer(100, 150, 45, &[_]Stop{}, .linear_rgb),
            },
        },
        .{
            .name = "non-default interpolation method",
            .args = .{
                .type = .{ .conic = .{
                    .x = 100,
                    .y = 150,
                    .angle = 45,
                } },
                .method = .{ .hsl = .increasing },
            },
            .expected = .{
                .conic = Conic.initBuffer(100, 150, 45, &[_]Stop{}, .{ .hsl = .increasing }),
            },
        },
    };
    const TestFn = struct {
        fn f(tc: anytype) TestingError!void {
            {
                const alloc = testing.allocator;
                var got = Gradient.init(tc.args);
                try testing.expectEqual(tc.expected, got);
                defer got.deinit(alloc);
                try got.addStop(alloc, 0.0, .{ .rgb = .{ 0, 0, 0 } });
                try got.addStop(alloc, 1.0, .{ .rgb = .{ 1, 1, 1 } });
                debug.assert(@TypeOf(got.getPixel(0, 0)) == pixel.Pixel);
                debug.assert(@TypeOf(got.getOffset(0, 0)) == f32);
                try testing.expectEqualDeep(
                    Stop.List.SearchResult{
                        .c0 = .{ .linear_rgb = .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 1.0 } },
                        .c1 = .{ .linear_rgb = .{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 } },
                        .offset = 0.5,
                    },
                    got.searchInStops(0.5),
                );
                try testing.expectEqual(tc.args.method, got.getInterpolationMethod());
            }

            {
                var stops: [2]Stop = undefined;
                var args = tc.args;
                args.stops = &stops;
                var got = Gradient.init(args);
                got.addStopAssumeCapacity(0.0, .{ .rgb = .{ 0, 0, 0 } });
                got.addStopAssumeCapacity(1.0, .{ .rgb = .{ 1, 1, 1 } });
                try testing.expectEqualDeep(
                    Stop.List.SearchResult{
                        .c0 = .{ .linear_rgb = .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 1.0 } },
                        .c1 = .{ .linear_rgb = .{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 } },
                        .offset = 0.5,
                    },
                    got.searchInStops(0.5),
                );
            }
        }
    };
    try runCases(name, cases, TestFn.f);
}
