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
///
/// TODO: Add bevel join
pub const JoinMode = enum {
    /// Lines are joined with a miter (pointed end).
    ///
    /// See the miter_limit setting in DrawContext for details on how to
    /// control the miter limit.
    miter,

    /// Lines are joined with a circle centered around the middle point of the
    /// joined line.
    round,

    /// Lines are joined with a bevel (cut-off). The cut-off points are taken
    /// at the outer adjoining line ends as they would be seen if the lines
    /// were not closed.
    bevel,
};
