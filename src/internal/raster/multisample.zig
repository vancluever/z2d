const math = @import("std").math;
const mem = @import("std").mem;
const heap = @import("std").heap;
const testing = @import("std").testing;

const compositor = @import("../../compositor.zig");
const pixel = @import("../../pixel.zig");

const FillRule = @import("../../options.zig").FillRule;
const Pattern = @import("../../pattern.zig").Pattern;
const Surface = @import("../../surface.zig").Surface;
const Polygon = @import("../tess/Polygon.zig");
const SparseCoverageBuffer = @import("sparse_coverage.zig").SparseCoverageBuffer;
const compositeOpaque = @import("shared.zig").compositeOpaque;
const compositeOpacity = @import("shared.zig").compositeOpacity;

const runCases = @import("../util.zig").runCases;
const TestingError = @import("../util.zig").TestingError;

pub const scale = 4;

pub fn run(
    alloc: mem.Allocator,
    surface: *Surface,
    pattern: *const Pattern,
    polygons: Polygon,
    fill_rule: FillRule,
    operator: compositor.Operator,
    precision: compositor.Precision,
) mem.Allocator.Error!void {
    const coverage_full = scale * scale;
    const alpha_scale: i32 = 256 / coverage_full;

    const sfc_width: i32 = surface.getWidth();
    const sfc_height: i32 = surface.getHeight();
    const _precision = if (operator.requiresFloat()) .float else precision;
    if (!polygons.inBox(scale, surface.getWidth(), surface.getHeight())) {
        return;
    }

    // Our draw methodology is actually quite similar to paintDirect in that we
    // composite per-scanline, versus the supersample approach where we create
    // a mask first, downsample, it, and then paint that to a particular
    // location. As such, our draw area is taken as a scanline range, versus a
    // box.
    const start_scanline: i32 = math.clamp(
        @as(i32, @intFromFloat(@floor(polygons.extent_top / scale))),
        0,
        sfc_height - 1,
    );
    // NOTE: The clamping on end_scanline to (sfc_height - 1) versus sfc_height
    // has been shipped from paintDirect. This is apparently designed to catch
    // single-line-height cases, but reviewing the code there (and here), this
    // is only employed in scanline iteration and could probably use a review.
    //
    // For now though, we're leaving it alone, but note that scanline_end_x
    // below "correctly" clamps to the surface width as it does not necessarily
    // need to worry about scanlines, but rather controls the x-bounds of the
    // draw area for both the coverage buffer length and also clear area for
    // unbounded operations.
    const end_scanline: i32 = math.clamp(
        @as(i32, @intFromFloat(@ceil(polygons.extent_bottom / scale))),
        start_scanline,
        sfc_height - 1,
    );

    // We create our coverage buffer once and reset it separately, this is
    // because reset is simple so we don't need to tie it into the arena.
    const scanline_start_x: i32 = math.clamp(
        @as(i32, @intFromFloat(@floor(polygons.extent_left / scale))),
        0,
        sfc_width - 1,
    );
    const scanline_end_x: i32 = math.clamp(
        @as(i32, @intFromFloat(@ceil(polygons.extent_right / scale))),
        scanline_start_x,
        sfc_width,
    );

    const scanline_draw_width = scanline_end_x - scanline_start_x;
    if (scanline_draw_width < 1) {
        // Should have already been validated by inBox
        @panic("invalid mask dimensions. this is a bug, please report it");
    }
    var coverage_buffer = try SparseCoverageBuffer.init(alloc, @max(0, scanline_draw_width));
    defer coverage_buffer.deinit(alloc);

    // We need a scaled x-offset that we need to use when adding spans
    // (subtracting/pulling back) or drawing out spans (adding/pushing
    // forward), and a scaled draw width to clamp to.
    const scanline_start_x_scaled = scanline_start_x * scale;
    const scanline_draw_width_scaled = scanline_draw_width * scale;

    // Clear out the area not covered by the draw area when we're dealing with
    // unbounded operators.
    if (!operator.isBounded()) {
        // Do any full scanlines first
        for (0..@max(0, start_scanline)) |y_u|
            surface.clearStride(0, @intCast(y_u), @max(0, sfc_width));
        for (@max(0, end_scanline + 1)..@max(0, sfc_width)) |y_u|
            surface.clearStride(0, @intCast(y_u), @max(0, sfc_width));

        // Now, do the strides outside of the draw area on the same scanlines
        for (@max(0, start_scanline)..@max(0, end_scanline) + 1) |y_u| {
            if (scanline_start_x > 0) surface.clearStride(0, @intCast(y_u), @max(0, scanline_start_x));
            if (scanline_end_x < sfc_width) {
                surface.clearStride(0, @intCast(y_u), @max(0, sfc_width - scanline_end_x));
            }
        }
    }

    // Our working edge set that survives a particular scanline iteration. This
    // is re-fetched at particular breakpoints, but only incremented on
    // otherwise.
    var working_edge_set: Polygon.WorkingEdgeSet = try .init(alloc, &polygons);
    defer working_edge_set.deinit(alloc);

    // Fetch our breakpoints
    var y_breakpoints = try working_edge_set.breakpoints(alloc);
    defer y_breakpoints.deinit(alloc);
    var y_breakpoint_idx: usize = y_breakpoint_idx: {
        for (y_breakpoints.items, 0..) |y, idx| {
            if (y >= start_scanline) {
                break :y_breakpoint_idx idx -| 1;
            }
        }

        // No breakpoints cross y=start_scanline, this is a no-op
        return;
    };

    for (@max(0, start_scanline)..@max(0, end_scanline) + 1) |y_u| {
        defer coverage_buffer.reset();
        const y: i32 = @intCast(y_u);

        const y_scaled: i32 = y * scale;
        for (0..4) |y_offset| {
            const y_scanline_scaled: i32 = y_scaled + @as(i32, @intCast(y_offset));
            if (y_scanline_scaled >= y_breakpoints.items[y_breakpoint_idx]) {
                // y-breakpoint passed, re-calculate our working edge set.
                working_edge_set.rescan(y_scanline_scaled);
                if (y_breakpoint_idx < y_breakpoints.items.len - 1) y_breakpoint_idx += 1;
            }

            working_edge_set.inc(y_scanline_scaled);
            working_edge_set.sort();
            const filtered_edge_set = working_edge_set.filter(fill_rule);

            // x_min controls the last x-position on the scanline we've
            // recorded (i.e., the end of the last span) and serves as the
            // minimum that the next span can start at. This is a safety
            // measure to ensure that no span overlaps can cause issues with
            // coverage overflowing, etc.
            var x_min: i32 = 0;

            for (0..filtered_edge_set.len / 2) |edge_pair_idx| {
                const edge_pair_start = edge_pair_idx * 2;
                // Pull back the scaled device space co-ordinates (similar to
                // supersample).
                const start_x: i32 = @max(
                    x_min,
                    filtered_edge_set[edge_pair_start] - scanline_start_x_scaled,
                );
                if (start_x >= scanline_draw_width_scaled) {
                    // We're past the end of the draw area and can stop
                    // drawing.
                    break;
                }

                // Clamping here is done to the length of the scanline coverage
                // buffer with the supersampled co-ordinate scale applied. In
                // principle, this is similar to the clamping we do in SSAA
                // (i.e., clamping to the width of the mask, not the width of
                // the final target surface).
                const end_x: i32 = math.clamp(
                    filtered_edge_set[edge_pair_start + 1] - scanline_start_x_scaled,
                    start_x,
                    scanline_draw_width_scaled,
                );
                const fill_len: i32 = end_x - start_x;

                if (fill_len > 0) {
                    addSpan(&coverage_buffer, @max(0, start_x), @max(0, fill_len));
                }

                x_min = end_x;
            }
        }

        // Make sure we can't go beyond the actual capacity of the coverage
        // buffer (guard against bad recorded span len)
        const coverage_x_max = @min(coverage_buffer.len, coverage_buffer.capacity);
        // Write out all of the values in our scanline coverage buffer.
        var coverage_x_u: u32 = 0;
        while (coverage_x_u < coverage_x_max) {
            // Apply our offset to the co-ordinates in the scanline buffer
            const x: i32 = @as(i32, @intCast(coverage_x_u)) + scanline_start_x;
            const coverage_val_raw, const coverage_len_raw = coverage_buffer.get(coverage_x_u);
            // Clamp our coverage values (guards against uninitialized values
            // in the sparse buffer)
            const coverage_val: u8 = math.clamp(coverage_val_raw, 0, coverage_full);
            const coverage_len: u32 = @min(coverage_len_raw, @max(0, sfc_width - x));
            switch (coverage_val) {
                0 => {}, // Skip zero entries
                coverage_full => {
                    // Fully opaque span, so we can just composite directly (no alpha).
                    compositeOpaque(operator, surface, pattern, x, y, coverage_len, _precision);
                },
                else => {
                    // Span with some degree of (> 0, < max) opacity, so we
                    // need to grab that value, turn it into an alpha8 pixel,
                    // and composite that across our span.
                    compositeOpacity(
                        operator,
                        surface,
                        pattern,
                        x,
                        y,
                        coverage_len,
                        _precision,
                        @intCast(math.clamp(coverage_val * alpha_scale - 1, 0, 255)),
                    );
                },
            }

            coverage_x_u += coverage_len; // Advance to next buffer entry
        }
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
fn addSpan(cb: *SparseCoverageBuffer, x: u32, len: u32) void {
    if (x + len > cb.capacity * scale) {
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
        cb.addSpan(start_x, scale, front_len);
        const end_coverage: u8 = @min(scale, len - front_len * scale);
        if (end_coverage > 0) {
            // Only add end coverage if we need it
            cb.addSingle(start_x + front_len, end_coverage);
        }
    } else {
        // Write out front
        const start_coverage_raw: u8 = @min(scale, @min(len, scale - start_offset));
        cb.addSingle(start_x, start_coverage_raw);

        // Write out middle (if needed)
        const after_start_raw = len - start_coverage_raw;
        const mid_len: u32 = after_start_raw / scale;
        if (mid_len > 0) {
            cb.addSpan(start_x + 1, scale, mid_len);
        }

        // Write out end (if needed)
        const end_coverage_raw = @min(scale, after_start_raw - mid_len * scale);
        if (end_coverage_raw > 0) {
            cb.addSingle(start_x + 1 + mid_len, end_coverage_raw);
        }
    }
}

test "addSpan" {
    // Simple triangle in the midpoint/cross-section, assuming a scanline
    // edge of (50, 0) to (149, 0), so len = 100. We start out and expand
    // in.
    const alloc = testing.allocator;
    var coverage: SparseCoverageBuffer = try .init(alloc, 1024);
    defer coverage.deinit(alloc);
    addSpan(&coverage, 200, 400);
    try testing.expectEqual(.{ 4, 100 }, coverage.get(50));

    addSpan(&coverage, 201, 398);
    try testing.expectEqual(.{ 7, 1 }, coverage.get(50));
    try testing.expectEqual(.{ 8, 98 }, coverage.get(51));
    try testing.expectEqual(.{ 7, 1 }, coverage.get(149));

    addSpan(&coverage, 202, 396);
    try testing.expectEqual(.{ 9, 1 }, coverage.get(50));
    try testing.expectEqual(.{ 12, 98 }, coverage.get(51));
    try testing.expectEqual(.{ 9, 1 }, coverage.get(149));

    addSpan(&coverage, 203, 394);
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

            addSpan(&coverage, 0, cap_supersample);
            got_val, got_len = coverage.get(0);
            try testing.expectEqual(4, got_val);
            try testing.expectEqual(tc.capacity, got_len);

            addSpan(&coverage, 1, cap_supersample - 2);
            got_val, got_len = coverage.get(0);
            try testing.expectEqual(7, got_val);
            try testing.expectEqual(1, got_len);
            got_val, got_len = coverage.get(1);
            try testing.expectEqual(8, got_val);
            try testing.expectEqual(tc.capacity - 2, got_len);
            got_val, got_len = coverage.get(tc.capacity - 1);
            try testing.expectEqual(7, got_val);
            try testing.expectEqual(1, got_len);

            addSpan(&coverage, 2, cap_supersample - 4);
            got_val, got_len = coverage.get(0);
            try testing.expectEqual(9, got_val);
            try testing.expectEqual(1, got_len);
            got_val, got_len = coverage.get(1);
            try testing.expectEqual(12, got_val);
            try testing.expectEqual(tc.capacity - 2, got_len);
            got_val, got_len = coverage.get(tc.capacity - 1);
            try testing.expectEqual(9, got_val);
            try testing.expectEqual(1, got_len);

            addSpan(&coverage, 3, cap_supersample - 6);
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
