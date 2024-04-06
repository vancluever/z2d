const mem = @import("std").mem;

const surfacepkg = @import("surface.zig");
const patternpkg = @import("pattern.zig");
const pixelpkg = @import("pixel.zig");
const options = @import("options.zig");
const PathOperation = @import("path/path.zig").PathOperation;
const fillerpkg = @import("path/filler.zig");
const strokerpkg = @import("path/stroker.zig");

/// The draw context, which connects patterns to surfaces, holds other state
/// data, and is used to dispatch drawing operations.
pub const DrawContext = struct {
    /// The underlying surface.
    surface: surfacepkg.Surface,

    /// The underlying pattern.
    ///
    /// The default pattern is RGBA opaque black.
    pattern: patternpkg.Pattern = .{
        .opaque_pattern = .{
            .pixel = .{ .rgba = .{ .r = 0x00, .g = 0x00, .b = 0x00, .a = 0xFF } },
        },
    },

    /// The current line width for drawing operations, in pixels. This value is
    /// taken at call time during stroke operations in a path, and has no
    /// effect during path construction.
    ///
    /// The default line width is 2.0.
    line_width: f64 = 2.0,

    /// The current fill rule. The default is non_zero.
    fill_rule: options.FillRule = .non_zero,

    /// The current line join style for stroking. The default is miter.
    line_join_mode: options.JoinMode = .miter,

    /// The limit when line_join_mode is set to miter; in this mode, this value
    /// determines when the join is instead drawn as a bevel. This can be used
    /// to prevent extremely large miter points that result from very sharp
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

    /// The current line cap rule. The default is butt.
    line_cap_mode: options.CapMode = .butt,

    /// The current anti-aliasing mode. The default is the aptly-named
    /// "default" anti-aliasing mode.
    anti_aliasing_mode: options.AntiAliasMode = .default,

    /// Runs a fill operation on the path(s) in the supplied set. All paths in
    /// the set must be closed.
    ///
    /// This is a no-op if there are no nodes.
    pub fn fill(self: *DrawContext, alloc: mem.Allocator, path: PathOperation) !void {
        if (path.nodes.items.len == 0) return;
        if (!path.closed()) return error.PathNotClosed;

        try fillerpkg.fill(
            alloc,
            path.nodes,
            self.surface,
            self.pattern,
            self.anti_aliasing_mode,
            self.fill_rule,
        );
    }

    /// Strokes a line for the path(s) in the supplied set.
    ///
    /// The behavior of open and closed paths are different for stroking. For
    /// open paths (not explicitly closed with closePath), the start and the
    /// end of the line are capped using the style set in line_cap_mode (e.g.,
    /// butt, round, or square). For closed paths (ones that *are* explicitly
    /// closed with closePath), the intersection joint of the start and end are
    /// instead joined, along with all other joints along the way, with the
    /// style set in line_join_mode (e.g., miter, round, or bevel).
    ///
    /// This is a no-op if there are no nodes.
    pub fn stroke(self: *DrawContext, alloc: mem.Allocator, path: PathOperation) !void {
        if (path.nodes.items.len == 0) return;
        try strokerpkg.stroke(
            alloc,
            path.nodes,
            self.surface,
            self.pattern,
            self.anti_aliasing_mode,
            self.line_width,
            self.line_join_mode,
            self.miter_limit,
            self.line_cap_mode,
        );
    }
};
