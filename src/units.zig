const math = @import("std").math;

/// Represents a point in 2D space.
pub const Point = struct {
    x: f64,
    y: f64,

    /// Checks to see if a point is equal to another point.
    pub fn equal(self: Point, other: Point) bool {
        return self.x == other.x and self.y == other.y;
    }
};
