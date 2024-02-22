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
