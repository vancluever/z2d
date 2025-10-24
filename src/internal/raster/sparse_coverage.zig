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

const runCases = @import("../util.zig").runCases;
const TestingError = @import("../util.zig").TestingError;

/// A structure for representing run-length-encoded coverage for a single
/// scanline. This facilities anti-aliasing by allowing the recording of
/// coverage spans over single or multiple calls. In memory, this is stored
/// as two sparse buffers; one for the coverage as a []u8, and the other for
/// lengths whose underlying type is dependent on the total capacity; most
/// notably, this means that the coverage and length storage combined will only
/// use a maximum of 510 bytes of memory for scanlines of less than 256 pixels.
///
/// Calculating actual coverage to add or set is an exercise local to the
/// specific rasterizer, i.e., no calculations for scale, etc, are not done
/// here.
///
/// An example of how coverage is recorded is discussed here, in the MSAA
/// context (see rasterizer/multiplesample.zig for more details):
///
/// To use the buffer when performing MSAA composition, spans are recorded in
/// groups of `scale` in super-sampled space (appropriately offset to fully
/// take advantage of the above space optimization for span lengths). After
/// recording the full set of sub-scanlines, values are written out by
/// x-coordinates in device space starting at x=0, and incrementing on the
/// length returned by `get`. As the `value` is the total coverage in pixels,
/// make sure to take the set count and calculate the actual opacity as a
/// multiple of `256 / (scale * scale)`, subtracting 1 and clamping afterwards
/// to give the 0-255 range.
///
/// Consider also fast-pathing when the coverage value is either 0 or the
/// maximum (i.e., `scale * scale`).
///
/// Note that in an effort to keep this hot-path code fast, it's expected that
/// any safety guarantees, e.g., bounding x-coordinates, clamping opacity
/// values, ensuring pixels are not counted more than once, are provided by the
/// caller.
pub const SparseCoverageBuffer = struct {
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
        switch (self.lengths) {
            inline else => |l| alloc.free(l),
        }
        self.* = undefined;
    }

    pub fn reset(self: *SparseCoverageBuffer) void {
        self.len = 0;
        switch (self.lengths) {
            inline else => |l| l[0] = 0,
        }
    }

    pub fn addSpan(self: *SparseCoverageBuffer, x: u32, value: u8, len: u32) void {
        self.extend(x, len);
        var x_cur: u32 = x;
        const x_end: u32 = x + len;
        while (x_cur < x_end) {
            var coverage_value, const coverage_len = self.get(x_cur);
            coverage_value += value;
            self.putValue(x_cur, coverage_value);
            x_cur += coverage_len;
        }
    }

    pub fn addSingle(self: *SparseCoverageBuffer, x: u32, value: u8) void {
        self.extend(x, 1);
        var coverage_value, _ = self.get(x);
        coverage_value += value;
        self.putValue(x, coverage_value);
    }

    pub fn setSpan(self: *SparseCoverageBuffer, x: u32, value: u8, len: u32) void {
        self.extend(x, len);
        var x_cur: u32 = x;
        const x_end: u32 = x + len;
        while (x_cur < x_end) {
            var coverage_value, const coverage_len = self.get(x_cur);
            coverage_value = value;
            self.putValue(x_cur, coverage_value);
            x_cur += coverage_len;
        }
    }

    pub fn subSingle(self: *SparseCoverageBuffer, x: u32, value: u8) void {
        self.extend(x, 1);
        var coverage_value, _ = self.get(x);
        coverage_value -= value;
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
            } else if (rem == current_len) {
                break;
            }

            rem -= current_len;
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
