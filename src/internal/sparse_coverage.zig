// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024-2025 Chris Marchesi
//   Copyright 2006 The Android Open Source Project
//   Copyright 2020 Yevhenii Reizner
//
// Portions of the code in this file have been derived and adapted from the
// tiny-skia project (https://github.com/linebender/tiny-skia), notably
// alpha_runs.rs.

const math = @import("std").math;
const mem = @import("std").mem;
const testing = @import("std").testing;
const debug = @import("std").debug;

const runCases = @import("util.zig").runCases;
const TestingError = @import("util.zig").TestingError;

/// A structure for representing run-length-encoded coverage for a single
/// scanline. This facilities MSAA by taking supersampled co-ordinates and
/// recording the coverage as the number of pixels set in a particular unit of
/// scale (currently hardcoded to 4x). In memory, this is stored as two sparse
/// buffers; one for the coverage as a []u8, and the other for lengths whose
/// underlying type is dependent on the total capacity; most notably, this
/// means that the coverage and length storage combined will only use a maximum
/// of 510 bytes of memory for scanlines of less than 256 pixels.
///
/// To use the buffer when performing MSAA composition, record spans in groups
/// of `scale` in super-sampled space (appropriately offset to fully take
/// advantage of the above space optimization for span lengths), then write the
/// values out by x-coordinates in device space starting at x=0, and
/// incrementing on the length returned by `get`. As the `value` is the total
/// coverage in pixels, make sure to take the set count and calculate the
/// actual opacity as a multiple of `256 / (scale * scale)`, subtracting 1 and
/// clamping afterwards to give the 0-255 range.
///
/// Consider also fast-pathing when the coverage value is either 0 or the
/// maximum (i.e., `scale * scale`).
///
/// Note that in an effort to keep this hot-path code fast, it's expected that
/// any safety guarantees, e.g., bounding x-coordinates, clamping opacity
/// values, ensuring pixels are not counted more than once, are provided by the
/// caller.
pub const SparseCoverageBuffer = struct {
    pub const scale = 4;

    values: []u8,
    lengths: LengthStorage,
    len: u32,
    capacity: u32,

    pub fn init(alloc: mem.Allocator, capacity: u32) mem.Allocator.Error!SparseCoverageBuffer {
        const values = try alloc.alloc(u8, capacity);
        errdefer alloc.free(values);
        const lengths: LengthStorage = if (capacity < 256)
            .{ .u8 = try alloc.alloc(u8, capacity) }
        else if (capacity < 65536)
            .{ .u16 = try alloc.alloc(u16, capacity) }
        else
            .{ .u32 = try alloc.alloc(u32, capacity) };
        switch (lengths) {
            inline else => |r| r[0] = 0,
        }

        return .{
            .values = values,
            .lengths = lengths,
            .len = 0,
            .capacity = capacity,
        };
    }

    pub fn deinit(self: *SparseCoverageBuffer, alloc: mem.Allocator) void {
        alloc.free(self.values);
        self.values = undefined;
        switch (self.lengths) {
            inline else => |l| alloc.free(l),
        }
        self.lengths = undefined;
        self.len = undefined;
    }

    pub fn reset(self: *SparseCoverageBuffer) void {
        self.len = 0;
        switch (self.lengths) {
            inline else => |l| l[0] = 0,
        }
    }

    /// Adds a span at `x`, running for `len`. Both `x` and `len` must be
    /// supplied in super-sampled co-ordinates. Assumes that co-ordinates have
    /// already been appropriately clamped correctly to be non-negative and
    /// cropped for length (e.g., x=-5, len=10 should be clamped and clipped to
    /// x=0, len=5).
    ///
    /// Will extend the coverage set if necessary by adding space and/or
    /// splitting spans, before adding the coverage for the span.
    pub fn addSpan(self: *SparseCoverageBuffer, x: u32, len: u32) void {
        if (x + len > self.capacity * scale) {
            @panic("attempt to add span beyond capacity. this is a bug, please report it");
        }

        if (len == 0) return;

        // Start co-ordinates and coverage
        const start_x: u32 = x / scale;
        const start_offset: u32 = x - start_x * scale; // Bit offset of start-x

        if (start_offset == 0 and len >= scale) {
            // Start coverage is full, so optimize this by writing out full
            // coverage for the maximum length that we can, then write out the end
            // (if needed).
            const front_len: u32 = len / scale; // Opaque span len
            self.extendAndSetOpaque(start_x, front_len);
            const end_coverage: u8 = @min(scale, len - front_len * scale);
            if (end_coverage > 0) {
                // Only add end coverage if we need it
                self.extendAndSetSingle(start_x + front_len, end_coverage);
            }
        } else {
            // Write out front
            const start_coverage_raw: u8 = @min(scale, @min(len, scale - start_offset));
            self.extendAndSetSingle(start_x, start_coverage_raw);

            // Write out middle (if needed)
            const after_start_raw = len - start_coverage_raw;
            const mid_len: u32 = after_start_raw / scale;
            if (mid_len > 0) {
                self.extendAndSetOpaque(start_x + 1, mid_len);
            }

            // Write out end (if needed)
            const end_coverage_raw = @min(scale, after_start_raw - mid_len * scale);
            if (end_coverage_raw > 0) {
                self.extendAndSetSingle(start_x + 1 + mid_len, end_coverage_raw);
            }
        }
    }

    fn extendAndSetOpaque(self: *SparseCoverageBuffer, x: u32, len: u32) void {
        self.extend(x, len);
        var x_cur: u32 = x;
        const x_end: u32 = x + len;
        while (x_cur < x_end) {
            var coverage_value, const coverage_len = self.get(x_cur);
            coverage_value += scale;
            self.putValue(x_cur, coverage_value);
            x_cur += coverage_len;
        }
    }

    fn extendAndSetSingle(self: *SparseCoverageBuffer, x: u32, value: u8) void {
        self.extend(x, 1);
        var coverage_value, _ = self.get(x);
        coverage_value += value;
        self.putValue(x, coverage_value);
    }

    /// Extends the buffer depending on the specified (x, len).
    ///
    /// When neither x nor len are out of range, extends the buffer by adding a
    /// split span at the head or tail of the union of all the spans in (x, x +
    /// len).
    ///
    /// When len is out of range, but x is not, extends the buffer by adding a
    /// unique span at the end of the buffer, and then splitting the buffer as
    /// per the previous case (i.e., the new (x, x + len) range will encompass
    /// the union of all spans back from the end, appropriately split, and the
    /// new span at the end).
    ///
    /// When x is out of range, extends the buffer by adding two spans: one
    /// from the end to x, and then from x to x + len.
    fn extend(self: *SparseCoverageBuffer, x: u32, len: u32) void {
        if (len == 0) return;

        // Check for situations where our x is fully out of range.
        if (x == self.len) {
            // Right on the range boundary, just need to add one span at the end.
            self.put(x, 0, len);
            self.len = x + len;
            return;
        }

        if (x > self.len) {
            // Past the range boundary, so we need to add a span for the
            // difference before adding the actual span (similar to a wholly
            // new entry).
            self.put(self.len, 0, x - self.len);
            self.put(x, 0, len);
            self.len = x + len;
            return;
        }

        // Split from the front first, checking any runs necessary to
        // insert the key with an appropriate new sparse length.
        self.splitInner(0, x);

        // Now we can split forward from our length to any remainders as
        // needed.
        //
        // First, check our span-to-add against the existing length.
        const span_len: u32 = x + len;
        if (span_len > self.len) {
            // We need to extend past the existing length, so we add the empty
            // span first before we split any necessary remainder.
            //
            // NOTE: extends for out-of-range indexes are handled higher up
            // (similar to empty sets).
            self.put(self.len, 0, span_len - self.len);
            self.len = span_len;
        }

        self.splitInner(x, len);
    }

    fn splitInner(self: *SparseCoverageBuffer, x: u32, len: u32) void {
        var idx = x;
        var rem = len;
        while (true) {
            const current_value, const current_len = self.get(idx);
            if (rem < current_len) {
                self.put(idx, current_value, rem);
                self.put(idx + rem, current_value, current_len - rem);
                break;
            }

            rem -= current_len;
            if (rem == 0) {
                return;
            }

            idx += current_len;
        }
    }

    pub fn get(self: *SparseCoverageBuffer, x: u32) struct { u8, u32 } {
        return .{
            self.values[x],
            switch (self.lengths) {
                inline else => |l| l[x],
            },
        };
    }

    fn put(self: *SparseCoverageBuffer, x: u32, value: u8, len: u32) void {
        debug.assert(x + len <= self.capacity);
        self.values[x] = value;
        switch (self.lengths) {
            inline else => |l| l[x] = @intCast(len),
        }
    }

    fn putValue(self: *SparseCoverageBuffer, x: u32, value: u8) void {
        self.values[x] = value;
    }

    const LengthStorage = union(enum) {
        u8: []u8,
        u16: []u16,
        u32: []u32,
    };
};

test "extend, basic" {
    const alloc = testing.allocator;
    var coverage: SparseCoverageBuffer = try .init(alloc, 10);
    defer coverage.deinit(alloc);
    coverage.put(0, 0, 4);
    coverage.put(4, 0, 4);
    coverage.len = 8;
    coverage.extend(2, 5);
    try testing.expectEqual(8, coverage.len);
    try testing.expectEqual(.{ 0, 2 }, coverage.get(0));
    try testing.expectEqual(.{ 0, 2 }, coverage.get(2));
    try testing.expectEqual(.{ 0, 3 }, coverage.get(4));
    try testing.expectEqual(.{ 0, 1 }, coverage.get(7));
}

test "extend, new buffer (zero-indexed initial span)" {
    const alloc = testing.allocator;
    var coverage: SparseCoverageBuffer = try .init(alloc, 10);
    defer coverage.deinit(alloc);
    coverage.extend(0, 5);
    try testing.expectEqual(5, coverage.len);
    try testing.expectEqual(.{ 0, 5 }, coverage.get(0));
}

test "extend, new buffer (non-zero initial span)" {
    const alloc = testing.allocator;
    var coverage: SparseCoverageBuffer = try .init(alloc, 10);
    defer coverage.deinit(alloc);
    coverage.extend(2, 5);
    try testing.expectEqual(7, coverage.len);
    try testing.expectEqual(.{ 0, 2 }, coverage.get(0));
    try testing.expectEqual(.{ 0, 5 }, coverage.get(2));
}

test "extend, split closer to the end (no extend)" {
    const alloc = testing.allocator;
    var coverage: SparseCoverageBuffer = try .init(alloc, 10);
    defer coverage.deinit(alloc);
    coverage.put(0, 0, 4);
    coverage.put(4, 0, 4);
    coverage.len = 8;
    coverage.extend(7, 1);
    try testing.expectEqual(8, coverage.len);
    try testing.expectEqual(.{ 0, 4 }, coverage.get(0));
    try testing.expectEqual(.{ 0, 3 }, coverage.get(4));
    try testing.expectEqual(.{ 0, 1 }, coverage.get(7));
}

test "extend, split closer to the end (with extend)" {
    const alloc = testing.allocator;
    var coverage: SparseCoverageBuffer = try .init(alloc, 10);
    defer coverage.deinit(alloc);
    coverage.put(0, 0, 4);
    coverage.put(4, 0, 4);
    coverage.len = 8;
    coverage.extend(7, 3);
    try testing.expectEqual(10, coverage.len);
    try testing.expectEqual(.{ 0, 4 }, coverage.get(0));
    try testing.expectEqual(.{ 0, 3 }, coverage.get(4));
    try testing.expectEqual(.{ 0, 1 }, coverage.get(7));
    try testing.expectEqual(.{ 0, 2 }, coverage.get(8));
}

test "extend, append right after end" {
    const alloc = testing.allocator;
    var coverage: SparseCoverageBuffer = try .init(alloc, 10);
    defer coverage.deinit(alloc);
    coverage.put(0, 0, 4);
    coverage.put(4, 0, 4);
    coverage.len = 8;
    coverage.extend(8, 2);
    try testing.expectEqual(10, coverage.len);
    try testing.expectEqual(.{ 0, 4 }, coverage.get(0));
    try testing.expectEqual(.{ 0, 4 }, coverage.get(4));
    try testing.expectEqual(.{ 0, 2 }, coverage.get(8));
}

test "extend, put something past end of buffer" {
    const alloc = testing.allocator;
    var coverage: SparseCoverageBuffer = try .init(alloc, 11);
    defer coverage.deinit(alloc);
    coverage.put(0, 0, 4);
    coverage.put(4, 0, 4);
    coverage.len = 8;
    coverage.extend(9, 2);
    try testing.expectEqual(11, coverage.len);
    try testing.expectEqual(.{ 0, 4 }, coverage.get(0));
    try testing.expectEqual(.{ 0, 4 }, coverage.get(4));
    try testing.expectEqual(.{ 0, 1 }, coverage.get(8));
    try testing.expectEqual(.{ 0, 2 }, coverage.get(9));
}

test "extend, zero len" {
    const alloc = testing.allocator;
    var coverage: SparseCoverageBuffer = try .init(alloc, 10);
    defer coverage.deinit(alloc);
    coverage.extend(0, 0);
    _, const got_len = coverage.get(0);
    try testing.expectEqual(0, got_len);
}

test "addSpan" {
    // Simple triangle in the midpoint/cross-section, assuming a scanline
    // edge of (50, 0) to (149, 0), so len = 100. We start out and expand
    // in.
    const alloc = testing.allocator;
    var coverage: SparseCoverageBuffer = try .init(alloc, 1024);
    defer coverage.deinit(alloc);
    coverage.addSpan(200, 400);
    try testing.expectEqual(.{ 4, 100 }, coverage.get(50));

    coverage.addSpan(201, 398);
    try testing.expectEqual(.{ 7, 1 }, coverage.get(50));
    try testing.expectEqual(.{ 8, 98 }, coverage.get(51));
    try testing.expectEqual(.{ 7, 1 }, coverage.get(149));

    coverage.addSpan(202, 396);
    try testing.expectEqual(.{ 9, 1 }, coverage.get(50));
    try testing.expectEqual(.{ 12, 98 }, coverage.get(51));
    try testing.expectEqual(.{ 9, 1 }, coverage.get(149));

    coverage.addSpan(203, 394);
    try testing.expectEqual(.{ 10, 1 }, coverage.get(50));
    try testing.expectEqual(.{ 16, 98 }, coverage.get(51));
    try testing.expectEqual(.{ 10, 1 }, coverage.get(149));

    var x: u32 = 0;
    var tracked_span_len: usize = 0;
    while (x < coverage.len) {
        _, const x_inc = coverage.get(x);
        x += x_inc;
        tracked_span_len += 1;
    }
    try testing.expectEqual(4, tracked_span_len);
}

test "addSpan, capacity tests/checks" {
    // As above, just deliberately checking capacities (most of the other tests
    // will just be initializing u8 length buffers).
    //
    // Note that these tests use a lot of memory, approx 655K peak!
    // I don't really think this is an issue though, since our acceptance test
    // suite (in spec/) uses probably about this much in general (or much more)
    // in our supersample tests. Consider our small capacity case: 2 []u8's
    // (one for values, one for lengths), with a maximum supported scanline
    // length of 255, yields only 510 bytes needed for the entire buffer;
    // compare this to a supersample case of 255x255: 260100 bytes (255x255x4)!
    // This is actually a great demonstration of the savings that we're getting
    // using the sparse buffer, even with the small amount of the space that's
    // actually used in it.
    //
    // Regardless, if it's an issue, you can get this test using a modest
    // amount of RAM by removing the larger tests (the ones past the u8
    // boundary, particularly).

    const name = "addSpan, capacity tests/checks";
    const cases = [_]struct {
        name: []const u8,
        capacity: u32,
        expected_T: []const u8,
    }{
        .{
            .name = "u8 (max case)",
            .capacity = 255,
            .expected_T = "u8",
        },
        .{
            .name = "u16 (u8 boundary)",
            .capacity = 256,
            .expected_T = "u16",
        },
        .{
            .name = "u16 (max case)",
            .capacity = 65535,
            .expected_T = "u16",
        },
        .{
            .name = "u32 (u16 boundary)",
            .capacity = 65536,
            .expected_T = "u32",
        },
        .{
            .name = "u32",
            .capacity = 131072,
            .expected_T = "u32",
        },
    };
    const TestFn = struct {
        fn f(tc: anytype) TestingError!void {
            const alloc = testing.allocator;
            var coverage: SparseCoverageBuffer = try .init(alloc, tc.capacity);
            defer coverage.deinit(alloc);
            try testing.expectEqualSlices(u8, tc.expected_T, @tagName(coverage.lengths));

            var got_val: u8 = undefined;
            var got_len: u32 = undefined;

            const cap_supersample = tc.capacity * 4;

            coverage.addSpan(0, cap_supersample);
            got_val, got_len = coverage.get(0);
            try testing.expectEqual(4, got_val);
            try testing.expectEqual(tc.capacity, got_len);

            coverage.addSpan(1, cap_supersample - 2);
            got_val, got_len = coverage.get(0);
            try testing.expectEqual(7, got_val);
            try testing.expectEqual(1, got_len);
            got_val, got_len = coverage.get(1);
            try testing.expectEqual(8, got_val);
            try testing.expectEqual(tc.capacity - 2, got_len);
            got_val, got_len = coverage.get(tc.capacity - 1);
            try testing.expectEqual(7, got_val);
            try testing.expectEqual(1, got_len);

            coverage.addSpan(2, cap_supersample - 4);
            got_val, got_len = coverage.get(0);
            try testing.expectEqual(9, got_val);
            try testing.expectEqual(1, got_len);
            got_val, got_len = coverage.get(1);
            try testing.expectEqual(12, got_val);
            try testing.expectEqual(tc.capacity - 2, got_len);
            got_val, got_len = coverage.get(tc.capacity - 1);
            try testing.expectEqual(9, got_val);
            try testing.expectEqual(1, got_len);

            coverage.addSpan(3, cap_supersample - 6);
            got_val, got_len = coverage.get(0);
            try testing.expectEqual(10, got_val);
            try testing.expectEqual(1, got_len);
            got_val, got_len = coverage.get(1);
            try testing.expectEqual(16, got_val);
            try testing.expectEqual(tc.capacity - 2, got_len);
            got_val, got_len = coverage.get(tc.capacity - 1);
            try testing.expectEqual(10, got_val);
            try testing.expectEqual(1, got_len);

            var x: u32 = 0;
            var tracked_span_len: usize = 0;
            while (x < coverage.len) {
                _, const x_inc = coverage.get(x);
                x += x_inc;
                tracked_span_len += 1;
            }
            try testing.expectEqual(3, tracked_span_len);
        }
    };
    try runCases(name, cases, TestFn.f);
}

// Uncomment this to test (expect assertion failure or intCast safety check)
//
// test "extend, split over underlying type max" {
//     const alloc = testing.allocator;
//     var coverage: SparseCoverageBuffer = try .init(alloc, 255);
//     defer coverage.deinit(alloc);
//     coverage.extend(192, 500);
//     var idx: u32 = 0;
//     while (idx < coverage.len) {
//         const x_val, const x_inc = coverage.get(idx);
//         debug.print("(idx: {d:>3}) x_val: {d}, x_inc: {d}, next: {d}\n", .{
//             idx,
//             x_val,
//             x_inc,
//             idx + x_inc,
//         });
//         idx += x_inc;
//     }
// }

test "extend, split up to exactly capacity" {
    const alloc = testing.allocator;
    var coverage: SparseCoverageBuffer = try .init(alloc, 255);
    defer coverage.deinit(alloc);

    // Just a note to get past morning brain, since we're working on the bit
    // boundaries here, remember that our capacity is 255, which means an
    // allowable index range of 0-254, *not* 0-255 (you're thinking of a
    // capacity of 256 here ;p).
    coverage.extend(192, 63);

    var got_val, var got_len = coverage.get(0);
    try testing.expectEqual(0, got_val);
    try testing.expectEqual(192, got_len);
    got_val, got_len = coverage.get(192);
    try testing.expectEqual(0, got_val);
    try testing.expectEqual(63, got_len);

    var idx: u32 = 0;
    var tracked_span_len: usize = 0;
    while (idx < coverage.len) {
        _, const x_inc = coverage.get(idx);
        idx += x_inc;
        tracked_span_len += 1;
    }
    try testing.expectEqual(2, tracked_span_len);
}
