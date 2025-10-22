const debug = @import("std").debug;
const heap = @import("std").heap;
const math = @import("std").math;
const mem = @import("std").mem;

const compositor = @import("../../compositor.zig");
const pixel = @import("../../pixel.zig");

const FillRule = @import("../../options.zig").FillRule;
const Pattern = @import("../../pattern.zig").Pattern;
const Surface = @import("../../surface.zig").Surface;
const SurfaceType = @import("../../surface.zig").SurfaceType;
const Polygon = @import("../tess/Polygon.zig");
const fillReducesToSource = @import("shared.zig").fillReducesToSource;

pub const Error = Surface.Error || mem.Allocator.Error;

pub fn run(
    alloc: mem.Allocator,
    surface: *Surface,
    pattern: *const Pattern,
    polygons: Polygon,
    fill_rule: FillRule,
    scale: f64,
    operator: compositor.Operator,
    precision: compositor.Precision,
) Error!void {
    // Do an initial check to see if our polygon is within the surface, if it
    // isn't, it's a no-op.
    //
    // This also enforces positive and non-zero surface dimensions, and
    // correctly defined polygon extents (e.g., that the end extents are
    // greater than the start extents).
    if (!polygons.inBox(scale, surface.getWidth(), surface.getHeight())) {
        return;
    }

    // This math expects integer scaling.
    debug.assert(@floor(scale) == scale);
    const i_scale: i32 = @intFromFloat(scale);

    // This is the area on the original image which our polygons may touch (in
    // the event our operator is bounded, otherwise it's the whole of the
    // surface).
    //
    // This range has to accommodate the extents of any possible point in the
    // polygon rectangle, so it needs to be "pushed out"; floored on the
    // top/left, and ceilinged on the bottom/right.
    const bounded = operator.isBounded();
    const x0: i32 = if (bounded) @intFromFloat(@floor(polygons.extent_left / scale)) else 0;
    const y0: i32 = if (bounded) @intFromFloat(@floor(polygons.extent_top / scale)) else 0;
    const x1: i32 = if (bounded)
        @intFromFloat(@ceil(polygons.extent_right / scale))
    else
        surface.getWidth();
    const y1: i32 = if (bounded)
        @intFromFloat(@ceil(polygons.extent_bottom / scale))
    else
        surface.getHeight();

    var mask_sfc = sfc_m: {
        // We calculate a scaled up version of the
        // extents for our supersampled drawing.
        //
        // These dimensions are clamped to the target surface to avoid
        // edge cases and unnecessary work.
        const target_width_scaled: i32 = surface.getWidth() * i_scale;
        const target_height_scaled: i32 = surface.getHeight() * i_scale;
        const box_x0: i32 = math.clamp(x0 * i_scale, 0, target_width_scaled - 1);
        const box_y0: i32 = math.clamp(y0 * i_scale, 0, target_height_scaled - 1);
        const box_x1: i32 = math.clamp(x1 * i_scale, box_x0, target_width_scaled - 1);
        const box_y1: i32 = math.clamp(y1 * i_scale, box_y0, target_height_scaled - 1);
        const mask_width: i32 = (box_x1 + 1) - box_x0;
        const mask_height: i32 = (box_y1 + 1) - box_y0;

        if (mask_width < 1 or mask_height < 1) {
            // This should have been checked earlier, if we hit this, it's a bug.
            @panic("invalid mask dimensions. this is a bug, please report it");
        }

        // Check our surface type. If we are one of our < 8bpp alpha surfaces,
        // we use that type instead.
        const surface_type: SurfaceType = switch (surface.*) {
            .image_surface_alpha4, .image_surface_alpha2, .image_surface_alpha1 => surface.*,
            else => .image_surface_alpha8,
        };
        const opaque_px: pixel.Pixel = switch (surface_type) {
            .image_surface_alpha4 => pixel.Alpha4.Opaque.asPixel(),
            .image_surface_alpha2 => pixel.Alpha2.Opaque.asPixel(),
            .image_surface_alpha1 => pixel.Alpha1.Opaque.asPixel(),
            else => pixel.Alpha8.Opaque.asPixel(),
        };
        var mask_sfc_scaled = try Surface.init(
            surface_type,
            alloc,
            mask_width,
            mask_height,
        );
        errdefer mask_sfc_scaled.deinit(alloc);

        // Fetch our breakpoints
        var y_breakpoints = try polygons.yBreakPoints(alloc);
        defer y_breakpoints.deinit(alloc);
        var y_breakpoint_idx: usize = y_breakpoint_idx: {
            for (y_breakpoints.items, 0..) |y, idx| {
                if (y >= box_y0) {
                    break :y_breakpoint_idx idx -| 1;
                }
            }

            // No breakpoints cross y=box_y0, this is a no-op
            return;
        };

        // Our working edge set that survives a particular scanline iteration. This
        // is re-fetched at particular breakpoints, but only incremented on
        // otherwise.
        var working_edge_set: Polygon.WorkingEdgeSet = .empty;

        // Make an ArenaAllocator for our working edge set, this allows us to
        // re-use the same memory after refresh by simply resetting the arena.
        var edge_arena = heap.ArenaAllocator.init(alloc);
        defer edge_arena.deinit();
        const edge_alloc = edge_arena.allocator();

        for (0..@max(0, mask_height)) |y_u| {
            const y: i32 = @intCast(y_u);
            const dev_y: i32 = y + box_y0; // Device-space y-coordinate (still supersampled)

            if (dev_y >= y_breakpoints.items[y_breakpoint_idx]) {
                // y-breakpoint passed, re-calculate our working edge set.
                _ = edge_arena.reset(.retain_capacity);
                working_edge_set = try polygons.xEdgesForY(
                    edge_alloc,
                    dev_y,
                );
                if (y_breakpoint_idx < y_breakpoints.items.len - 1) y_breakpoint_idx += 1;
            }

            working_edge_set.inc(dev_y);
            working_edge_set.sort();
            const filtered_edge_set = working_edge_set.filter(fill_rule);

            for (0..filtered_edge_set.len / 2) |edge_pair_idx| {
                // Inverse to the above; pull back our scaled device space
                // co-ordinates to mask space.
                const edge_pair_start = edge_pair_idx * 2;
                const start_x: i32 = @max(
                    0,
                    filtered_edge_set[edge_pair_start] - box_x0,
                );
                if (start_x >= mask_width) {
                    // We're past the mask draw area and can stop drawing.
                    break;
                }
                const end_x: i32 = math.clamp(
                    filtered_edge_set[edge_pair_start + 1] - box_x0,
                    start_x,
                    mask_width,
                );

                const fill_len: i32 = end_x - start_x;
                if (fill_len > 0) {
                    mask_sfc_scaled.paintStride(start_x, y, @max(0, fill_len), opaque_px);
                }
            }
        }

        mask_sfc_scaled.downsample(alloc);
        break :sfc_m mask_sfc_scaled;
    };
    defer mask_sfc.deinit(alloc);

    // We only bother clamping here on the low end since we've clipped
    // upper-left overlaps at (0,0). Offsets out of bounds of the surface
    // should have been filtered by the polygon/surface check at the start of
    // the function (and the compositor will ignore out-of-surface offsets
    // too).
    const comp_x: i32 = @max(0, x0);
    const comp_y: i32 = @max(0, y0);
    compositor.SurfaceCompositor.run(surface, comp_x, comp_y, 2, .{
        .{
            .operator = .dst_in,
            .dst = switch (pattern.*) {
                .opaque_pattern => .{ .pixel = pattern.opaque_pattern.pixel },
                .gradient => .{ .gradient = pattern.gradient },
                .dither => .{ .dither = pattern.dither },
            },
            .src = .{ .surface = &mask_sfc },
        },
        .{
            .operator = operator,
        },
    }, .{ .precision = precision });
}
