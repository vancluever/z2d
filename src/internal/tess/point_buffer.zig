const Point = @import("../Point.zig");

/// A buffer of points. When empty, the buffer fills up to the maximum, and
/// then rotates the elements according to the value of split; the number of
/// elements equal to the split are kept, and the rest are swapped in a FIFO
/// basis.
///
/// This is applied in fill and stroke: in fill, it stores the initial point
/// along with the last two points, in stroke, it stores enough data to
/// reconstruct the first join, if need be.
///
/// All helpers that return a point will return null if the respective index is
/// invalid.
pub fn PointBuffer(split: usize, buffer_len: usize) type {
    return struct {
        const Self = @This();
        items: [buffer_len]Point = undefined,

        len: usize = 0,

        pub fn add(self: *Self, item: Point) void {
            if (self.len < buffer_len) {
                self.items[self.len] = item;
                self.len += 1;
            } else {
                for (split..buffer_len - 1) |idx| self.items[idx] = self.items[idx + 1];
                self.items[buffer_len - 1] = item;
            }
        }

        pub fn reset(self: *Self) void {
            self.len = 0;
        }

        /// Returns the start of the buffer with the offset in `n` applied, as
        /// `self.items[n]`.
        pub fn head(self: Self, n: usize) ?Point {
            if (n >= self.len) return null;
            return self.items[n];
        }

        /// Returns the end of the buffer with the offset in `n` applied, as
        /// `self.items[self.len - n]`.
        pub fn tail(self: Self, n: usize) ?Point {
            if (n == 0) @panic("invalid tail index");
            if (self.len < n) return null;
            return self.items[self.len - n];
        }

        pub fn last(self: Self) ?Point {
            if (self.len == 0) return null;
            return self.items[self.len - 1];
        }

        pub fn first(self: Self) ?Point {
            if (self.len == 0) return null;
            return self.items[0];
        }
    };
}
