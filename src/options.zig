// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024-2025 Chris Marchesi

//! Documents option enumerations used in various parts of the library, mostly
//! in `Context`.

const _ = struct {}; // Used to fix autodoc, ignore

/// The default maximum error tolerance used in spline and arc calculations.
pub const default_tolerance: f64 = 0.1;

/// Represents the kinds of fill rules for paths. This will determine how more
/// complex paths are filled, such as in the situation where multiple sub-paths
/// overlap, or a single sub-path traces its path in a way where its lines will
/// cross each other (consider the path undertaken when tracing a star, for
/// example).
///
/// The core concept that makes a fill rule is how it determines its
/// "insideness", or the areas to be filled.
///
/// Note that the exact internal implementation details for a particular fill
/// rule may not match the descriptions here.
pub const FillRule = enum {
    /// Determines the insideness by drawing a ray from any point to infinity
    /// in any direction, with a starting count of zero. For any line that
    /// crosses from left to right, add 1, and for any line that crosses from
    /// right to left, subtract one. After all lines are crossed and accounted
    /// for, if the result is zero, the point is outside of the path and not
    /// drawn, otherwise it's inside and drawn.
    non_zero,

    /// Determines the insideness by drawing a ray from any point to infinity
    /// in any direction, counting the number of crossings on the way out. If
    /// after all crossings are accounted for, if the count is even, the point
    /// is outside of the path and not drawn, otherwise it's inside and drawn.
    even_odd,
};

/// Represents how lines are joined when stroking paths.
pub const JoinMode = enum {
    /// Lines are joined with a miter (pointed end).
    ///
    /// See `Context.setMiterLimit` for details on how to control the miter
    /// limit.
    miter,

    /// Lines are joined with a circle centered around the middle point of the
    /// joined line.
    round,

    /// Lines are joined with a bevel (cut-off). The cut-off points are taken
    /// at the outer adjoining line ends as they would be seen if the lines
    /// were not closed.
    bevel,
};

/// Represents how lines are capped when stroking paths.
pub const CapMode = enum {
    /// Lines are cut off at the ends, right at their center point
    /// perpendicular to their thickness. In other words, a path will not
    /// extend beyond the two endpoints.
    butt,

    /// Lines are rounded at the ends.
    round,

    /// Lines are squared on the ends, to the thickness / 2.
    square,
};

/// Represents the anti-aliasing mode used when drawing paths, which smoothes
/// out jagged lines (aka "jaggies"). `none` represents no anti-aliasing.
pub const AntiAliasMode = enum {
    none,
    default,
};
