// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024 Chris Marchesi

//! Context is the draw context, which connects patterns to surfaces, holds
//! other state data, and is used to dispatch drawing operations.
const Context = @This();

const mem = @import("std").mem;

const options = @import("options.zig");

const Painter = @import("internal/Painter.zig");
const Path = @import("Path.zig");
const Pattern = @import("pattern.zig").Pattern;
const Surface = @import("surface.zig").Surface;
const Transformation = @import("Transformation.zig");
const PathError = @import("errors.zig").PathError;

/// The underlying surface.
surface: Surface,

/// The underlying pattern.
///
/// The default pattern is RGBA opaque black.
pattern: Pattern = .{
    .opaque_pattern = .{
        .pixel = .{ .rgba = .{ .r = 0x00, .g = 0x00, .b = 0x00, .a = 0xFF } },
    },
},

/// The current line width for drawing operations, in pixels. This value is
/// taken at call time during `stroke` operations, and has no effect during path
/// construction.
line_width: f64 = 2.0,

/// The current fill rule. Note that `stroke` operations always fill non-zero,
/// regardless of this setting.
fill_rule: options.FillRule = .non_zero,

/// The current line join style for `stroke` operations.
line_join_mode: options.JoinMode = .miter,

/// The limit when `line_join_mode` is set to `.miter`; in this mode, this
/// value determines when the join is instead drawn as a bevel. This can be
/// used to prevent extremely large miter points that result from very sharp
/// angled joins.
///
/// The value here is the maximum allowed ratio of the miter distance (the
/// distance of the center of the stroke to the miter point) divided by the
/// line width. This is also described by 1 / sin(Θ / 2), where Θ is the
/// interior angle.
///
/// The default limit is 10.0, which sets the cutoff at ~11 degrees. A
/// miter limit of 2.0 translates to ~60 degrees, and a limit of 1.414
/// translates to ~90 degrees.
miter_limit: f64 = 10.0,

/// The current line cap rule for `stroke` operations.
line_cap_mode: options.CapMode = .butt,

/// The current anti-aliasing mode. The default is the aptly-named
/// "default" anti-aliasing mode.
anti_aliasing_mode: options.AntiAliasMode = .default,

/// The maximum error tolerance used for approximating curves and arcs. A
/// higher tolerance will give better performance, but "blockier" curves. The
/// default tolerance is 0.1, and values below this are unlikely to give better
/// visual results. This value has a minimum of 0.001, values below this are
/// clamped.
///
/// Note that this setting also affects the "virtual pen" used to draw rounded
/// caps and joins, which use static vertices for plotting. This can produce
/// marked artifacts at relatively low tolerance settings, so take care when
/// changing under these scenarios.
tolerance: f64 = options.default_tolerance,

/// The current transformation matrix (CTM) for this path.
///
/// The transformation matrix in a context is separate from the CTM in any
/// given `Path`. It has more subtle influences on drawing: in stroking, it
/// influences line width respective to scale, warping due to a warped scale
/// (e.g., different x and y scale), and any respective capping. In filling, it
/// is (currently) ignored.
///
/// Synchronization of CTM between here and `Path`, if desired, is currently an
/// exercise left to the consumer.
transformation: Transformation = Transformation.identity,

/// Runs a fill operation on the path(s) in the supplied set. All paths in the
/// set must be closed.
///
/// This is a no-op if there are no nodes.
pub fn fill(self: *Context, alloc: mem.Allocator, path: Path) !void {
    try (Painter{ .context = self }).fill(alloc, path.nodes.items);
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
pub fn stroke(self: *Context, alloc: mem.Allocator, path: Path) !void {
    try (Painter{ .context = self }).stroke(alloc, path.nodes.items);
}
