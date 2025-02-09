// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024 Chris Marchesi

//! Gradients are patterns that can be used to draw colors in a
//! position-dependent fashion, transitioning through a series of colors along
//! a specific axis.
//!
//! Currently, only `Linear` gradients are supported.
//!
//! Note that gradients always operate on (and return) RGBA values. Any pixel
//! values that are not RGBA will be converted before being added as a stop.

const std = @import("std");
const debug = @import("std").debug;
const math = @import("std").math;
const mem = @import("std").mem;
const testing = @import("std").testing;

const pixel = @import("pixel.zig");

const Pattern = @import("pattern.zig").Pattern;
const Point = @import("internal/Point.zig");

const vector_length = @import("compositor.zig").vector_length;

/// Interface tags for gradient types.
pub const GradientType = enum {
    linear,
};

/// Represents a linear gradient along a line.
pub const Linear = struct {
    start: Point,
    end: Point,

    /// The stops contained within the gradient. Add stops using
    /// `Stop.List.add` or `Stop.List.addAssumeCapacity`.
    stops: Stop.List,

    /// Initializes a linear gradient running from `(x0, y0)` to `(x1, y1)`.
    ///
    /// Before using the gradient, it's recommended to add some stops:
    ///
    /// ```
    /// var linear = Linear.init(0, 0, 99, 99);
    /// defer linear.deinit(alloc);
    /// try gradient.stops.add(alloc, 0, .{ .rgb = .{ .r = 255, .g = 0, .b = 0 } });
    /// try gradient.stops.add(alloc, 0.5, .{ .rgb = .{ .r = 0, .g = 255, .b = 0 } });
    /// try gradient.stops.add(alloc, 1, .{ .rgb = .{ .r = 0, .g = 0, .b = 255 } });
    /// ...
    /// ```
    ///
    /// As shown in the above example, `deinit` should be called to release any
    /// stops that have been added using `Stop.List.add`.
    pub fn init(x0: f64, y0: f64, x1: f64, y1: f64) Linear {
        return .{
            .start = .{ .x = x0, .y = y0 },
            .end = .{ .x = x1, .y = y1 },
            .stops = .{},
        };
    }

    /// Initializes the gradient with externally allocated memory for the
    /// stops. Do not use this with `deinit` or `Stop.List.add` as it will
    /// cause illegal behavior, use `Stop.List.addAssumeCapacity` instead.
    pub fn initBuffer(x0: f64, y0: f64, x1: f64, y1: f64, stops: []Stop) Linear {
        return .{
            .start = .{ .x = x0, .y = y0 },
            .end = .{ .x = x1, .y = y1 },
            .stops = .{ .l = std.ArrayListUnmanaged(Stop).initBuffer(stops) },
        };
    }

    /// Releases any stops that have been added using `Stop.List.add`. Must use
    /// the same allocator that was used there.
    pub fn deinit(self: *Linear, alloc: mem.Allocator) void {
        self.stops.deinit(alloc);
    }

    /// Returns this gradient as a pattern.
    pub fn asPatternInterface(self: *const Linear) Pattern {
        return .{ .linear_gradient = self };
    }

    /// Gets the pixel calculated for the gradient at `(x, y)`.
    pub fn getPixel(self: *const Linear, x: i32, y: i32) pixel.Pixel {
        return self.stops.search(self.getOffset(x, y)).lerp().asPixel();
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
    pub fn getOffset(self: *const Linear, x: i32, y: i32) f64 {
        return project(self.start, self.end, .{
            .x = @as(f64, @floatFromInt(x)),
            .y = @as(f64, @floatFromInt(y)),
        });
    }
};

/// Represents a color stop in a gradient.
///
/// Color stops within gradients are always stored as RGBA, they will be
/// converted according to the surface they are applied to.
pub const Stop = struct {
    idx: usize,

    /// The color for this color stop.
    color: pixel.RGBA,

    /// The offset of this color stop, clamped between `0.0` and `1.0`.
    offset: f64,

    /// Represents a list of color stops. Do not copy this field directly from
    /// gradient to gradient as it may cause the index to go out of sync.
    const List = struct {
        current_idx: usize = 0,
        l: std.ArrayListUnmanaged(Stop) = .{},

        /// Releases any memory allocated using `add`.
        fn deinit(self: *List, alloc: mem.Allocator) void {
            self.l.deinit(alloc);
        }

        /// Adds a color stop with the specified offset and pixel. The pixel
        /// will be converted to RGBA. The offset will be clamped to `0.0` and
        /// `1.0`.
        ///
        /// If stops are added at identical offsets, they will be stored in the
        /// order they were added. Looking up that particular offset will yield
        /// the first stop given, but going past that stop will start the next
        /// blend at last stop added.
        pub fn add(
            self: *List,
            alloc: mem.Allocator,
            offset: f64,
            px: pixel.Pixel,
        ) mem.Allocator.Error!void {
            const newlen = self.l.items.len + 1;
            try self.l.ensureTotalCapacity(alloc, newlen);
            self.addAssumeCapacity(offset, px);
        }

        /// Like `add`, but assumes the list can hold the stop.
        pub fn addAssumeCapacity(self: *List, offset: f64, px: pixel.Pixel) void {
            const _offset = math.clamp(offset, 0, 1);
            self.l.appendAssumeCapacity(.{
                .idx = self.current_idx,
                .color = pixel.RGBA.fromPixel(px),
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
            c0: pixel.RGBA,
            c1: pixel.RGBA,
            offset: f64,

            /// Performs linear interpolation on the search result, returning
            /// the respective color.
            pub fn lerp(self: SearchResult) pixel.RGBA {
                debug.assert(self.offset <= 1.0 and self.offset >= 0);
                const t_int: u16 = @intFromFloat(255.0 * self.offset);
                const c0_16_r: u16 = self.c0.r;
                const c0_16_g: u16 = self.c0.g;
                const c0_16_b: u16 = self.c0.b;
                const c0_16_a: u16 = self.c0.a;
                const c1_16_r: u16 = self.c1.r;
                const c1_16_g: u16 = self.c1.g;
                const c1_16_b: u16 = self.c1.b;
                const c1_16_a: u16 = self.c1.a;
                return .{
                    .r = lerp16to8(c0_16_r, c1_16_r, t_int),
                    .g = lerp16to8(c0_16_g, c1_16_g, t_int),
                    .b = lerp16to8(c0_16_b, c1_16_b, t_int),
                    .a = lerp16to8(c0_16_a, c1_16_a, t_int),
                };
            }

            fn lerp16to8(a: u16, b: u16, t: u16) u8 {
                return switch (a <= b) {
                    true => @intCast(a + (b - a) * t / 255),
                    false => @intCast(a - (a - b) * t / 255),
                };
            }
        };

        /// Returns a start color, an end color, and a relative offset within
        /// the stop list, suitable for linear interpolation.
        ///
        /// Offset is clamped to `0.0` and `1.0`.
        ///
        /// The result of an empty list is transparent black.
        pub fn search(self: *const List, offset: f64) SearchResult {
            if (self.l.items.len == 0) return .{
                .c0 = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
                .c1 = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
                .offset = 0,
            };
            const _offset = math.clamp(offset, 0, 1);
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

            // Our mid is now our "match": start = mid, end = mid + 1, at least
            // on our non-edge case. We do need to do some checking on edge
            // cases though, so do that now.
            while (mid > 0 and self.l.items[mid].offset == self.l.items[mid - 1].offset) {
                // We guarantee an order here for identical stops in that the
                // last one added is the last one returned, so in the event
                // that we land on a section of identical items, we need to
                // rewind until we are at the first entry.
                mid -= 1;
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

fn project(start: Point, end: Point, point: Point) f64 {
    const start_to_end_dx = end.x - start.x;
    const start_to_end_dy = end.y - start.y;
    const start_to_p_dx = point.x - start.x;
    const start_to_p_dy = point.y - start.y;
    return math.clamp(
        dot(
            f64,
            2,
            .{ start_to_end_dx, start_to_end_dy },
            .{ start_to_p_dx, start_to_p_dy },
        ) / dotSq(
            start_to_end_dx,
            start_to_end_dy,
        ),
        0,
        1,
    );
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
    };
    stop_list.addAssumeCapacity(0.75, .{ .rgba = .{ .r = 0xCC, .g = 0xCC, .b = 0xCC, .a = 0xCC } });
    stop_list.addAssumeCapacity(0.25, .{ .rgba = .{ .r = 0xAA, .g = 0xAA, .b = 0xAA, .a = 0xAA } });
    stop_list.addAssumeCapacity(0.9, .{ .rgba = .{ .r = 0xDD, .g = 0xDD, .b = 0xDD, .a = 0xDD } });
    stop_list.addAssumeCapacity(0.5, .{ .rgba = .{ .r = 0xBB, .g = 0xBB, .b = 0xBB, .a = 0xBB } });

    const expected = [_]Stop{
        .{ .idx = 1, .color = .{ .r = 0xAA, .g = 0xAA, .b = 0xAA, .a = 0xAA }, .offset = 0.25 },
        .{ .idx = 3, .color = .{ .r = 0xBB, .g = 0xBB, .b = 0xBB, .a = 0xBB }, .offset = 0.5 },
        .{ .idx = 0, .color = .{ .r = 0xCC, .g = 0xCC, .b = 0xCC, .a = 0xCC }, .offset = 0.75 },
        .{ .idx = 2, .color = .{ .r = 0xDD, .g = 0xDD, .b = 0xDD, .a = 0xDD }, .offset = 0.9 },
    };
    try testing.expectEqualDeep(&expected, stop_list.l.items);

    // clamped
    stop_list.addAssumeCapacity(-1.0, .{ .rgba = .{ .r = 0xEE, .g = 0xEE, .b = 0xEE, .a = 0xEE } });
    stop_list.addAssumeCapacity(2.0, .{ .rgba = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF, .a = 0xFF } });

    const expected_clamped = [_]Stop{
        .{ .idx = 4, .color = .{ .r = 0xEE, .g = 0xEE, .b = 0xEE, .a = 0xEE }, .offset = 0.0 },
        .{ .idx = 1, .color = .{ .r = 0xAA, .g = 0xAA, .b = 0xAA, .a = 0xAA }, .offset = 0.25 },
        .{ .idx = 3, .color = .{ .r = 0xBB, .g = 0xBB, .b = 0xBB, .a = 0xBB }, .offset = 0.5 },
        .{ .idx = 0, .color = .{ .r = 0xCC, .g = 0xCC, .b = 0xCC, .a = 0xCC }, .offset = 0.75 },
        .{ .idx = 2, .color = .{ .r = 0xDD, .g = 0xDD, .b = 0xDD, .a = 0xDD }, .offset = 0.9 },
        .{ .idx = 5, .color = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF, .a = 0xFF }, .offset = 1.0 },
    };
    try testing.expectEqualDeep(&expected_clamped, stop_list.l.items);

    // identical offset
    stop_list.addAssumeCapacity(0.25, .{ .rgba = .{ .r = 0x11, .g = 0x11, .b = 0x11, .a = 0x11 } });

    const expected_identical_offset = [_]Stop{
        .{ .idx = 4, .color = .{ .r = 0xEE, .g = 0xEE, .b = 0xEE, .a = 0xEE }, .offset = 0.0 },
        .{ .idx = 1, .color = .{ .r = 0xAA, .g = 0xAA, .b = 0xAA, .a = 0xAA }, .offset = 0.25 },
        .{ .idx = 6, .color = .{ .r = 0x11, .g = 0x11, .b = 0x11, .a = 0x11 }, .offset = 0.25 },
        .{ .idx = 3, .color = .{ .r = 0xBB, .g = 0xBB, .b = 0xBB, .a = 0xBB }, .offset = 0.5 },
        .{ .idx = 0, .color = .{ .r = 0xCC, .g = 0xCC, .b = 0xCC, .a = 0xCC }, .offset = 0.75 },
        .{ .idx = 2, .color = .{ .r = 0xDD, .g = 0xDD, .b = 0xDD, .a = 0xDD }, .offset = 0.9 },
        .{ .idx = 5, .color = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF, .a = 0xFF }, .offset = 1.0 },
    };
    try testing.expectEqualDeep(&expected_identical_offset, stop_list.l.items);
}

test "Stop.List.search" {
    // Zero elements
    var stop_list_zero: Stop.List = .{};
    try testing.expectEqualDeep(Stop.List.SearchResult{
        .c0 = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .c1 = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .offset = 0.0,
    }, stop_list_zero.search(0.5));

    // Actual tests
    var stops: [5]Stop = undefined;
    var stop_list: Stop.List = .{
        .l = std.ArrayListUnmanaged(Stop).initBuffer(&stops),
    };

    stop_list.addAssumeCapacity(0.25, .{ .rgba = .{ .r = 0xAA, .g = 0xAA, .b = 0xAA, .a = 0xAA } });
    stop_list.addAssumeCapacity(0.5, .{ .rgba = .{ .r = 0xBB, .g = 0xBB, .b = 0xBB, .a = 0xBB } });
    stop_list.addAssumeCapacity(0.75, .{ .rgba = .{ .r = 0xCC, .g = 0xCC, .b = 0xCC, .a = 0xCC } });
    stop_list.addAssumeCapacity(0.9, .{ .rgba = .{ .r = 0xDD, .g = 0xDD, .b = 0xDD, .a = 0xDD } });

    // basic
    var got = stop_list.search(0.6);
    var expected: Stop.List.SearchResult = .{
        .c0 = .{ .r = 0xBB, .g = 0xBB, .b = 0xBB, .a = 0xBB },
        .c1 = .{ .r = 0xCC, .g = 0xCC, .b = 0xCC, .a = 0xCC },
        .offset = 0.4,
    };
    try testing.expectEqualDeep(expected.c0, got.c0);
    try testing.expectEqualDeep(expected.c1, got.c1);
    try testing.expectApproxEqAbs(expected.offset, got.offset, math.floatEps(f64));

    // smaller interval
    got = stop_list.search(0.85);
    expected = .{
        .c0 = .{ .r = 0xCC, .g = 0xCC, .b = 0xCC, .a = 0xCC },
        .c1 = .{ .r = 0xDD, .g = 0xDD, .b = 0xDD, .a = 0xDD },
        .offset = 2.0 / 3.0,
    };
    try testing.expectEqualDeep(expected.c0, got.c0);
    try testing.expectEqualDeep(expected.c1, got.c1);
    try testing.expectApproxEqAbs(expected.offset, got.offset, math.floatEps(f64));

    // start
    got = stop_list.search(0.1);
    expected = .{
        .c0 = .{ .r = 0xAA, .g = 0xAA, .b = 0xAA, .a = 0xAA },
        .c1 = .{ .r = 0xAA, .g = 0xAA, .b = 0xAA, .a = 0xAA },
        .offset = 0.4,
    };
    try testing.expectEqualDeep(expected.c0, got.c0);
    try testing.expectEqualDeep(expected.c1, got.c1);
    try testing.expectApproxEqAbs(expected.offset, got.offset, math.floatEps(f64));

    // end
    got = stop_list.search(0.95);
    expected = .{
        .c0 = .{ .r = 0xDD, .g = 0xDD, .b = 0xDD, .a = 0xDD },
        .c1 = .{ .r = 0xDD, .g = 0xDD, .b = 0xDD, .a = 0xDD },
        .offset = 0.05,
    };
    try testing.expectEqualDeep(expected.c0, got.c0);
    try testing.expectEqualDeep(expected.c1, got.c1);
    try testing.expectApproxEqAbs(expected.offset, got.offset, math.floatEps(f64));

    // exactly 0
    got = stop_list.search(0.0);
    expected = .{
        .c0 = .{ .r = 0xAA, .g = 0xAA, .b = 0xAA, .a = 0xAA },
        .c1 = .{ .r = 0xAA, .g = 0xAA, .b = 0xAA, .a = 0xAA },
        .offset = 0.0,
    };
    try testing.expectEqualDeep(expected.c0, got.c0);
    try testing.expectEqualDeep(expected.c1, got.c1);
    try testing.expectApproxEqAbs(expected.offset, got.offset, math.floatEps(f64));

    // exactly 1
    got = stop_list.search(1.0);
    expected = .{
        .c0 = .{ .r = 0xDD, .g = 0xDD, .b = 0xDD, .a = 0xDD },
        .c1 = .{ .r = 0xDD, .g = 0xDD, .b = 0xDD, .a = 0xDD },
        .offset = 0.1,
    };
    try testing.expectEqualDeep(expected.c0, got.c0);
    try testing.expectEqualDeep(expected.c1, got.c1);
    try testing.expectApproxEqAbs(expected.offset, got.offset, math.floatEps(f64));

    // exact on stop
    got = stop_list.search(0.25);
    expected = .{
        .c0 = .{ .r = 0xAA, .g = 0xAA, .b = 0xAA, .a = 0xAA },
        .c1 = .{ .r = 0xBB, .g = 0xBB, .b = 0xBB, .a = 0xBB },
        .offset = 0.0,
    };
    try testing.expectEqualDeep(expected.c0, got.c0);
    try testing.expectEqualDeep(expected.c1, got.c1);
    try testing.expectApproxEqAbs(expected.offset, got.offset, math.floatEps(f64));

    // clamped ( < 0)
    got = stop_list.search(-1.0);
    expected = .{
        .c0 = .{ .r = 0xAA, .g = 0xAA, .b = 0xAA, .a = 0xAA },
        .c1 = .{ .r = 0xAA, .g = 0xAA, .b = 0xAA, .a = 0xAA },
        .offset = 0.0,
    };
    try testing.expectEqualDeep(expected.c0, got.c0);
    try testing.expectEqualDeep(expected.c1, got.c1);
    try testing.expectApproxEqAbs(expected.offset, got.offset, math.floatEps(f64));

    // clamped ( > 1)
    got = stop_list.search(2.0);
    expected = .{
        .c0 = .{ .r = 0xDD, .g = 0xDD, .b = 0xDD, .a = 0xDD },
        .c1 = .{ .r = 0xDD, .g = 0xDD, .b = 0xDD, .a = 0xDD },
        .offset = 0.1,
    };
    try testing.expectEqualDeep(expected.c0, got.c0);
    try testing.expectEqualDeep(expected.c1, got.c1);
    try testing.expectApproxEqAbs(expected.offset, got.offset, math.floatEps(f64));

    // Double offset
    //
    // It's expected that identical stops get pulled up in the order that
    // they're added, so c0 here will be AA and c1 will be EE.
    stop_list.addAssumeCapacity(0.25, .{ .rgba = .{ .r = 0xEE, .g = 0xEE, .b = 0xEE, .a = 0xEE } });
    got = stop_list.search(0.25);
    expected = .{
        .c0 = .{ .r = 0xAA, .g = 0xAA, .b = 0xAA, .a = 0xAA },
        .c1 = .{ .r = 0xEE, .g = 0xEE, .b = 0xEE, .a = 0xEE },
        .offset = 0.0,
    };
    try testing.expectEqualDeep(expected.c0, got.c0);
    try testing.expectEqualDeep(expected.c1, got.c1);
    try testing.expectApproxEqAbs(expected.offset, got.offset, math.floatEps(f64));
}

test "Linear.getPixel" {
    const alloc = testing.allocator;
    var gradient = Linear.init(0, 0, 99, 99);
    defer gradient.deinit(alloc);
    try gradient.stops.add(alloc, 0, .{ .rgb = .{ .r = 255, .g = 0, .b = 0 } });
    try gradient.stops.add(alloc, 0.5, .{ .rgb = .{ .r = 0, .g = 255, .b = 0 } });
    try gradient.stops.add(alloc, 1, .{ .rgb = .{ .r = 0, .g = 0, .b = 255 } });

    // Basic test along the gradient line, pretty much zero projection. You get
    // to see the rounding fun that happens though with some of the midpoints.
    // This is fine.
    try testing.expectEqualDeep(pixel.Pixel{ .rgba = .{
        .r = 255,
        .g = 0,
        .b = 0,
        .a = 255,
    } }, gradient.getPixel(0, 0));
    try testing.expectEqualDeep(pixel.Pixel{ .rgba = .{
        .r = 127,
        .g = 128,
        .b = 0,
        .a = 255,
    } }, gradient.getPixel(25, 25));
    try testing.expectEqualDeep(pixel.Pixel{ .rgba = .{
        .r = 0,
        .g = 255,
        .b = 0,
        .a = 255,
    } }, gradient.getPixel(49, 50));
    try testing.expectEqualDeep(pixel.Pixel{ .rgba = .{
        .r = 0,
        .g = 127,
        .b = 128,
        .a = 255,
    } }, gradient.getPixel(74, 75));
    try testing.expectEqualDeep(pixel.Pixel{ .rgba = .{
        .r = 0,
        .g = 0,
        .b = 255,
        .a = 255,
    } }, gradient.getPixel(99, 99));

    // Projection tests, to show the effect of orthogonal projection for pixels
    // not exactly on the gradient line (pretty much all pixels, really).
    try testing.expectEqualDeep(pixel.Pixel{ .rgba = .{
        .r = 255,
        .g = 0,
        .b = 0,
        .a = 255,
    } }, gradient.getPixel(-1, -1)); // Also tests past the line
    try testing.expectEqualDeep(pixel.Pixel{ .rgba = .{
        .r = 127,
        .g = 128,
        .b = 0,
        .a = 255,
    } }, gradient.getPixel(50, 0));
    try testing.expectEqualDeep(pixel.Pixel{ .rgba = .{
        .r = 0,
        .g = 255,
        .b = 0,
        .a = 255,
    } }, gradient.getPixel(0, 99));
    try testing.expectEqualDeep(pixel.Pixel{ .rgba = .{
        .r = 0,
        .g = 127,
        .b = 128,
        .a = 255,
    } }, gradient.getPixel(149, 0));
    try testing.expectEqualDeep(pixel.Pixel{ .rgba = .{
        .r = 0,
        .g = 0,
        .b = 255,
        .a = 255,
    } }, gradient.getPixel(0, 199));
}
