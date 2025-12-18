const heap = @import("std").heap;
const math = @import("std").math;
const mem = @import("std").mem;

const compositor = @import("../../compositor.zig");

const FillRule = @import("../../options.zig").FillRule;
const Pattern = @import("../../pattern.zig").Pattern;
const Surface = @import("../../surface.zig").Surface;
const InternalError = @import("../InternalError.zig").InternalError;
const Polygon = @import("../tess/Polygon.zig");
const commpositeOpaque = @import("shared.zig").compositeOpaque;

pub fn run(
    alloc: mem.Allocator,
    surface: *Surface,
    pattern: *const Pattern,
    polygons: Polygon,
    fill_rule: FillRule,
    operator: compositor.Operator,
    precision: compositor.Precision,
) mem.Allocator.Error!void {
    const sfc_width: i32 = surface.getWidth();
    const sfc_height: i32 = surface.getHeight();
    const _precision = if (operator.requiresFloat()) .float else precision;
    const bounded = operator.isBounded();

    // Do an initial check to see if our polygon is within the surface, if it
    // isn't, it's a no-op.
    //
    // This also enforces positive and non-zero surface dimensions, and
    // correctly defined polygon extents (e.g., that the end extents are
    // greater than the start extents).
    if (!polygons.inBox(1.0, sfc_width, sfc_height)) {
        return;
    }

    // This is the scanline range on the original image which our polygons may
    // touch (in the event our operator is bounded, otherwise it's the whole of
    // the surface).
    //
    // This range has to accommodate the extents of the top and bottom of the
    // polygon rectangle, so it needs to be "pushed out"; floored on the top,
    // and ceilinged on the bottom.
    const poly_start_y: i32 = if (bounded) @intFromFloat(@floor(polygons.extent_top)) else 0;
    const poly_end_y: i32 = if (bounded) @intFromFloat(@ceil(polygons.extent_bottom)) else sfc_height - 1;
    // Clamp the scanlines to the surface
    const start_scanline: i32 = math.clamp(poly_start_y, 0, sfc_height - 1);
    const end_scanline: i32 = math.clamp(poly_end_y, start_scanline, sfc_height - 1);

    // Our working edge set that survives a particular scanline iteration. This
    // is re-scanned at particular breakpoints, but only incremented on
    // otherwise.
    var working_edge_set: Polygon.WorkingEdgeSet = try .init(alloc, &polygons);
    defer working_edge_set.deinit(alloc);

    // Fetch our breakpoints
    var y_breakpoints = try working_edge_set.breakpoints(alloc);
    defer y_breakpoints.deinit(alloc);
    var y_breakpoint_idx: usize = y_breakpoint_idx: {
        // Seek to our starting breakpoint, given a possible clamping of y=0
        for (y_breakpoints.items, 0..) |y, idx| {
            if (y >= start_scanline) {
                break :y_breakpoint_idx idx -| 1;
            }
        }

        // No breakpoints cross y=start_scanline, this is a no-op
        return;
    };

    // Note that we have to add 1 to the end scanline here as our start -> end
    // boundaries above only account for+clamp to the last line to be scanned,
    // so our len is end + 1. This helps correct for scenarios like small
    // polygons laying on edges, or very small surfaces (e.g., 1 pixel high).
    for (@max(0, start_scanline)..@max(0, end_scanline) + 1) |y_u| {
        const y: i32 = @intCast(y_u);
        if (y >= y_breakpoints.items[y_breakpoint_idx]) {
            // y-breakpoint passed, re-calculate our working edge set.
            working_edge_set.rescan(y);
            if (y_breakpoint_idx < y_breakpoints.items.len - 1) y_breakpoint_idx += 1;
        }

        working_edge_set.inc(y);
        working_edge_set.sort();
        const filtered_edge_set = working_edge_set.filter(fill_rule);

        if (!bounded and filtered_edge_set.len == 0) {
            // Empty line but we're not bounded, so we clear the whole line.
            surface.clearStride(0, y, @max(0, sfc_width));
            continue;
        }

        for (0..filtered_edge_set.len / 2) |edge_pair_idx| {
            const edge_pair_start = edge_pair_idx * 2;
            const start_x: i32 = @max(
                0,
                filtered_edge_set[edge_pair_start],
            );
            if (start_x >= sfc_width) {
                // We're past the end of the draw area and can stop drawing.
                break;
            }
            const end_x: i32 = math.clamp(
                filtered_edge_set[edge_pair_start + 1],
                start_x,
                sfc_width,
            );
            const fill_len: i32 = end_x - start_x;
            const end_clear_len: i32 = sfc_width - end_x;

            if (!bounded and start_x > 0) {
                // Clear up to the start
                surface.clearStride(0, y, @max(0, start_x));
            }

            if (fill_len > 0) {
                commpositeOpaque(operator, surface, pattern, start_x, y, @max(0, fill_len), _precision);
            }

            if (!bounded and end_clear_len > 0) {
                // Clear to the end
                surface.clearStride(end_x, y, @max(0, end_clear_len));
            }
        }
    }
}
