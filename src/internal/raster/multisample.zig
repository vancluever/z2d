const math = @import("std").math;
const mem = @import("std").mem;
const heap = @import("std").heap;

const compositor = @import("../../compositor.zig");
const pixel = @import("../../pixel.zig");

const FillRule = @import("../../options.zig").FillRule;
const Pattern = @import("../../pattern.zig").Pattern;
const Surface = @import("../../surface.zig").Surface;
const Polygon = @import("../tess/Polygon.zig");
const SparseCoverageBuffer = @import("sparse_coverage.zig").SparseCoverageBuffer;
const fillReducesToSource = @import("shared.zig").fillReducesToSource;

pub fn run(
    alloc: mem.Allocator,
    surface: *Surface,
    pattern: *const Pattern,
    polygons: Polygon,
    fill_rule: FillRule,
    operator: compositor.Operator,
    precision: compositor.Precision,
) mem.Allocator.Error!void {
    const scale = SparseCoverageBuffer.scale;
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
                    coverage_buffer.addSpan(@max(0, start_x), @max(0, fill_len));
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
                    if (operator == .clear) {
                        surface.clearStride(x, y, coverage_len);
                    } else if (pattern.* == .opaque_pattern and
                        fillReducesToSource(operator, pattern.opaque_pattern.pixel))
                    {
                        surface.paintStride(x, y, coverage_len, pattern.opaque_pattern.pixel);
                    } else {
                        const dst_stride = surface.getStride(x, y, coverage_len);
                        compositor.StrideCompositor.run(dst_stride, &.{.{
                            .operator = operator,
                            .src = switch (pattern.*) {
                                .opaque_pattern => .{ .pixel = pattern.opaque_pattern.pixel },
                                .gradient => |g| .{ .gradient = .{
                                    .underlying = g,
                                    .x = x,
                                    .y = y,
                                } },
                                .dither => .{ .dither = .{
                                    .underlying = pattern.dither,
                                    .x = x,
                                    .y = y,
                                } },
                            },
                        }}, .{ .precision = _precision });
                    }
                },
                else => {
                    // Span with some degree of (> 0, < max) opacity, so we
                    // need to grab that value, turn it into an alpha8 pixel,
                    // and composite that across our span.
                    if (operator == .clear) {
                        surface.clearStride(x, y, coverage_len);
                    } else if (pattern.* == .opaque_pattern and
                        fillReducesToSource(operator, pattern.opaque_pattern.pixel))
                    {
                        surface.compositeStride(
                            x,
                            y,
                            coverage_len,
                            pattern.opaque_pattern.pixel,
                            operator,
                            @intCast(math.clamp(coverage_val * alpha_scale - 1, 0, 255)),
                        );
                    } else {
                        const dst_stride = surface.getStride(x, y, coverage_len);
                        const mask_px: pixel.Pixel = .{ .alpha8 = .{
                            .a = @intCast(math.clamp(coverage_val * alpha_scale - 1, 0, 255)),
                        } };
                        compositor.StrideCompositor.run(dst_stride, &.{
                            .{
                                .operator = .dst_in,
                                .dst = switch (pattern.*) {
                                    .opaque_pattern => .{ .pixel = pattern.opaque_pattern.pixel },
                                    .gradient => |g| .{ .gradient = .{
                                        .underlying = g,
                                        .x = x,
                                        .y = y,
                                    } },
                                    .dither => .{ .dither = .{
                                        .underlying = pattern.dither,
                                        .x = x,
                                        .y = y,
                                    } },
                                },
                                .src = .{ .pixel = mask_px },
                            },
                            .{
                                .operator = operator,
                            },
                        }, .{ .precision = precision });
                    }
                },
            }

            coverage_x_u += coverage_len; // Advance to next buffer entry
        }
    }
}
