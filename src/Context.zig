// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024 Chris Marchesi

//! `Context` represents the managed drawing interface to z2d. It holds a
//! `Path`, `Surface`, and `Pattern` that it uses for these operations and a
//! frontend for controlling various options for filling and stroking.
//!
//! Every field within the context is controllable via setters or other
//! frontend methods. It is recommended you do not manipulate the fields within
//! a context directly. If you do wish further control over the process than
//! what the context provides, you can use each underlying component in an
//! unmanaged fashion by following the patterns the context uses as an example.
const Context = @This();

const mem = @import("std").mem;

const options = @import("options.zig");
const painter = @import("painter.zig");

const Path = @import("Path.zig");
const Pixel = @import("pixel.zig").Pixel;
const Pattern = @import("pattern.zig").Pattern;
const Surface = @import("surface.zig").Surface;
const Transformation = @import("Transformation.zig");

alloc: mem.Allocator,
path: Path,
surface: *Surface,
pattern: Pattern = .{
    .opaque_pattern = .{
        .pixel = .{ .rgba = .{ .r = 0x00, .g = 0x00, .b = 0x00, .a = 0xFF } },
    },
},

anti_aliasing_mode: options.AntiAliasMode = .default,
fill_rule: options.FillRule = .non_zero,
line_cap_mode: options.CapMode = .butt,
line_join_mode: options.JoinMode = .miter,
line_width: f64 = 2.0,
miter_limit: f64 = 10.0,
tolerance: f64 = options.default_tolerance,
transformation: Transformation = Transformation.identity,

/// Initializes a `Context` with the passed in allocator and surface. Call deinit
/// to release the `Path` that is managed by the context.
pub fn init(alloc: mem.Allocator, surface: *Surface) mem.Allocator.Error!Context {
    return .{
        .alloc = alloc,
        .surface = surface,
        .path = try Path.initCapacity(alloc, 0),
    };
}

/// Releases all resources associated with this particular context, such as the
/// managed `Path`.
pub fn deinit(self: *Context) void {
    self.path.deinit(self.alloc);
    self.path = undefined;
}

/// Returns the current underlying pixel for the context's pattern.
pub fn getSource(self: *Context) Pixel {
    return switch (self.pattern) {
        .opaque_pattern => |p| p.pixel,
    };
}

/// Sets the context's pattern to the supplied `Pixel`. Fill and stroke
/// operations will draw with this pixel when they are called.
///
/// The default pattern is RGBA opaque black.
pub fn setSource(self: *Context, px: Pixel) void {
    self.pattern = .{ .opaque_pattern = .{ .pixel = px } };
}

/// Returns the current anti-aliasing mode.
pub fn getAntiAliasingMode(self: *Context) options.AntiAliasMode {
    return self.anti_aliasing_mode;
}

/// Sets the anti-aliasing mode for fill and stroke operations. The default is
/// to use anti-aliasing. For how each mode works, see the option's enum
/// documentation.
pub fn setAntiAliasingMode(self: *Context, anti_aliasing_mode: options.AntiAliasMode) void {
    self.anti_aliasing_mode = anti_aliasing_mode;
}

/// Returns the current fill rule for the context.
pub fn getFillRule(self: *Context) options.FillRule {
    return self.fill_rule;
}

/// Sets how edges are counted during fill operations. The default mode is
/// .non_zero.
pub fn setFillRule(self: *Context, fill_rule: options.FillRule) void {
    self.fill_rule = fill_rule;
}

/// Returns the current line cap mode for the context.
pub fn getLineCapMode(self: *Context) options.CapMode {
    return self.line_cap_mode;
}

/// Sets how the ends of lines are drawn during stroke operations, a process
/// known as "capping". The default cap mode is .butt.
pub fn setLineCapMode(self: *Context, line_cap_mode: options.CapMode) void {
    self.line_cap_mode = line_cap_mode;
}

/// Returns the current line join mode for the context.
pub fn getLineJoinMode(self: *Context) options.JoinMode {
    return self.line_join_mode;
}

/// Sets how lines are joined during stroke operations.
pub fn setLineJoinMode(self: *Context, line_join_mode: options.JoinMode) void {
    self.line_join_mode = line_join_mode;
}

/// Returns the current line width for the context.
pub fn getLineWidth(self: *Context) f64 {
    return self.line_width;
}

/// Sets the line width for stroking operations, in pixels. This value is taken
/// at call time of `stroke`, and has no effect during path construction.
pub fn setLineWidth(self: *Context, line_width: f64) void {
    self.line_width = line_width;
}

/// Returns the current miter limit for the context.
pub fn getMiterLimit(self: *Context) f64 {
    return self.miter_limit;
}

/// Sets the limit when `line_join_mode` is set to `.miter`; in this mode, this
/// value determines when the join is instead drawn as a bevel. This can be
/// used to prevent extremely large miter points that result from very sharp
/// angled joins.
///
/// The value here is the maximum allowed ratio of the miter distance (the
/// distance of the center of the stroke to the miter point) divided by the
/// line width. This is also described by 1 / sin(Θ / 2), where Θ is the
/// interior angle.
///
/// The default limit is 10.0, which sets the cutoff at ~11 degrees. A miter
/// limit of 2.0 translates to ~60 degrees, and a limit of 1.414 translates to
/// ~90 degrees.
pub fn setMiterLimit(self: *Context, miter_limit: f64) void {
    self.miter_limit = miter_limit;
}

/// Returns the current error tolerance for the context.
pub fn getTolerance(self: *Context) f64 {
    return self.tolerance;
}

/// Sets the maximum error tolerance used for approximating curves and arcs. A
/// higher tolerance will give better performance, but "blockier" curves. The
/// default tolerance is 0.1, and values below this are unlikely to give better
/// visual results. This value has a minimum of 0.001, values below this are
/// clamped.
///
/// Note that this setting also affects the "virtual pen" used to draw rounded
/// caps and joins, which use static vertices for plotting. This can produce
/// marked artifacts at relatively low tolerance settings, so take care when
/// changing under these scenarios.
pub fn setTolerance(self: *Context, tolerance: f64) void {
    self.tolerance = tolerance;
    self.path.tolerance = tolerance;
}

/// Returns the current transformation matrix (CTM) for the context.
pub fn getTransformation(self: *Context) Transformation {
    return self.transformation;
}

/// Modifies the current transformation matrix (CTM) by setting it equal to the
/// supplied matrix.
pub fn setTransformation(self: *Context, transformation: Transformation) void {
    self.transformation = transformation;
    self.path.transformation = transformation;
}

/// Modifies the current transformation matrix (CTM) to the identity matrix
/// (i.e., no transformation takes place).
pub fn setIdentity(self: *Context) void {
    self.setTransformation(Transformation.identity);
}

/// Modifies the current transformation matrix (CTM) by multiplying it with the
/// supplied matrix.
pub fn mul(self: *Context, a: Transformation) void {
    self.setTransformation(self.getTransformation().mul(a));
}

/// Modifies the current transformation matrix (CTM) by applying a co-ordinate
/// offset to the origin.
pub fn translate(self: *Context, tx: f64, ty: f64) void {
    self.setTransformation(self.getTransformation().translate(tx, ty));
}

/// Modifies the current transformation matrix (CTM) by rotating around the
/// origin by `angle` (in radians).
pub fn rotate(self: *Context, angle: f64) void {
    self.setTransformation(self.getTransformation().rotate(angle));
}

/// Modifies the current transformation matrix (CTM) by scaling by `(sx, sy)`.
/// When `sx` and `sy` are not equal, a stretching effect will be achieved.
pub fn scale(self: *Context, sx: f64, sy: f64) void {
    self.setTransformation(self.getTransformation().scale(sx, sy));
}

/// Applies the current transformation matrix (CTM) to the supplied `x` and `y`.
pub fn userToDevice(self: *Context, x: *f64, y: *f64) void {
    self.transformation.userToDevice(x, y);
}

/// Applies the current transformation matrix (CTM) to the supplied `x` and
/// `y`, but ignores translation.
pub fn userToDeviceDistance(self: *Context, x: *f64, y: *f64) void {
    self.transformation.userToDeviceDistance(x, y);
}

/// Applies the inverse of the current transformation matrix (CTM) to the
/// supplied `x` and `y`.
pub fn deviceToUser(self: *Context, x: *f64, y: *f64) Transformation.Error!void {
    try self.transformation.deviceToUser(x, y);
}

/// Applies the inverse of the current transformation matrix (CTM) to the
/// supplied `x` and `y`, but ignores translation.
pub fn deviceToUserDistance(self: *Context, x: *f64, y: *f64) Transformation.Error!void {
    try self.transformation.deviceToUserDistance(x, y);
}

/// Rests the path set, clearing all nodes and state.
pub fn resetPath(self: *Context) void {
    self.path.reset();
}

/// Starts a new path, and moves the current point to it.
pub fn moveTo(self: *Context, x: f64, y: f64) mem.Allocator.Error!void {
    try self.path.moveTo(self.alloc, x, y);
}

/// Begins a new sub-path relative to the current point. Calling this
/// without a current point triggers safety-checked undefined behavior.
pub fn relMoveTo(self: *Context, x: f64, y: f64) (Path.Error || mem.Allocator.Error)!void {
    try self.path.relMoveTo(self.alloc, x, y);
}

/// Draws a line from the current point to the specified point and sets
/// it as the current point. Acts as a `moveTo` instead if there is no
/// current point.
pub fn lineTo(self: *Context, x: f64, y: f64) mem.Allocator.Error!void {
    try self.path.lineTo(self.alloc, x, y);
}

/// Draws a line relative to the current point. Calling this without a
/// current point triggers safety-checked undefined behavior.
pub fn relLineTo(self: *Context, x: f64, y: f64) (Path.Error || mem.Allocator.Error)!void {
    try self.path.relLineTo(self.alloc, x, y);
}

/// Draws a cubic bezier with the three supplied control points from
/// the current point. The new current point is set to (x3, y3).
/// Calling this without a current point triggers safety-checked
/// undefined behavior.
pub fn curveTo(
    self: *Context,
    x1: f64,
    y1: f64,
    x2: f64,
    y2: f64,
    x3: f64,
    y3: f64,
) (Path.Error || mem.Allocator.Error)!void {
    try self.path.curveTo(self.alloc, x1, y1, x2, y2, x3, y3);
}

/// Draws a cubic bezier relative to the current point. Calling this
/// without a current point triggers safety-checked undefined behavior.
pub fn relCurveTo(
    self: *Context,
    x1: f64,
    y1: f64,
    x2: f64,
    y2: f64,
    x3: f64,
    y3: f64,
) (Path.Error || mem.Allocator.Error)!void {
    try self.path.relCurveTo(self.alloc, x1, y1, x2, y2, x3, y3);
}

/// Adds a circular arc of the given radius to the current path. The arc is
/// centered at (xc, yc), begins at angle1 and proceeds in the direction of
/// increasing angles (i.e., counterclockwise direction) to end at angle2.
///
/// If angle2 is less than angle1, it will be increased by 2 * Π until it's
/// greater than angle1.
///
/// Angles are measured at radians (to convert from degrees, multiply by Π /
/// 180).
///
/// If there's a current point, an initial line segment will be added to the
/// path to connect the current point to the beginning of the arc. If this
/// behavior is undesired, call `resetPath` before calling. This will trigger a
/// `moveTo` before the splines are plotted, creating a new subpath.
///
/// After this operation, the current point will be the end of the arc.
///
/// ## Drawing an ellipse
///
/// In order to draw an ellipse, use `arc` along with a transformation. The
/// following example will draw an elliptical arc at `(x, y)` bounded by the
/// rectangle of `width` by `height` (i.e., the rectangle controls the lengths
/// of the radii).
///
/// ```
/// const saved_ctm = context.getTransformation();
/// context.translate(x + width / 2, y + height / 2);
/// context.scale(width / 2, height / 2);
/// try context.arc(0, 0, 1, 0, 2 + math.pi);
/// context.setTransformation(saved_ctm);
/// ```
///
pub fn arc(
    self: *Context,
    xc: f64,
    yc: f64,
    radius: f64,
    angle1: f64,
    angle2: f64,
) (Path.Error || mem.Allocator.Error)!void {
    try self.path.arc(self.alloc, xc, yc, radius, angle1, angle2);
}

/// Like arc, but draws in the reverse direction, i.e., begins at angle1, and
/// moves in decreasing angles (i.e., counterclockwise direction) to end at
/// angle2. If angle2 is greater than angle1, it will be decreased by 2 * Π
/// until it's less than angle1.
pub fn arcNegative(
    self: *Context,
    xc: f64,
    yc: f64,
    radius: f64,
    angle1: f64,
    angle2: f64,
) (Path.Error || mem.Allocator.Error)!void {
    try self.path.arcNegative(self.alloc, xc, yc, radius, angle1, angle2);
}

/// Closes the path by drawing a line from the current point by the
/// starting point. No effect if there is no current point.
pub fn close(self: *Context) mem.Allocator.Error!void {
    try self.path.close(self.alloc);
}

/// Returns true if all subpaths in the path set are currently closed.
pub fn isPathClosed(self: *Context) bool {
    return self.path.isClosed();
}

/// Runs a fill operation on the path(s) in the supplied set. All paths in the
/// set must be closed.
///
/// This is a no-op if there are no nodes.
pub fn fill(self: *Context) painter.FillError!void {
    try painter.fill(
        self.alloc,
        self.surface,
        &self.pattern,
        self.path.nodes.items,
        .{
            .anti_aliasing_mode = self.anti_aliasing_mode,
            .fill_rule = self.fill_rule,
            .tolerance = self.tolerance,
        },
    );
}

/// Strokes a line for the path(s) in the supplied set.
///
/// The behavior of open and closed paths are different for stroking. For open
/// paths (not explicitly closed with `Path.close`), the start and the end of
/// the line are capped using the style set in `line_cap_mode` (see
/// `options.CapMode`). For closed paths (ones that *are* explicitly closed
/// with `Path.close`), the intersection joint of the start and end are instead
/// joined, as with with all other joints along the way, with the style set in
/// `line_join_mode` (see `options.JoinMode`).
///
/// This is a no-op if there are no nodes.
pub fn stroke(self: *Context) painter.StrokeError!void {
    try painter.stroke(
        self.alloc,
        self.surface,
        &self.pattern,
        self.path.nodes.items,
        .{
            .anti_aliasing_mode = self.anti_aliasing_mode,
            .line_cap_mode = self.line_cap_mode,
            .line_join_mode = self.line_join_mode,
            .line_width = self.line_width,
            .miter_limit = self.miter_limit,
            .tolerance = self.tolerance,
            .transformation = self.transformation,
        },
    );
}
