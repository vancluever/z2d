//! Case: Renders and strokes a star on a 300x300 surface.
//!
//! Note that this test also validates that we always fill strokes using the
//! non-zero rule, since drawing a star means tracing a path that overlaps as
//! you move from point to point.
const debug = @import("std").debug;
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "011_stroke_star";

pub fn render(alloc: mem.Allocator, aa_mode: z2d.AntiAliasMode) !z2d.Surface {
    const width = 300;
    const height = 300;
    const sfc = try z2d.Surface.init(.image_surface_rgb, alloc, width, height);

    var context: z2d.Context = .{
        .surface = sfc,
        .pattern = .{
            .opaque_pattern = .{
                .pixel = .{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } }, // White on black
            },
        },
        .line_width = 6,
        .anti_aliasing_mode = aa_mode,
    };

    var path = z2d.Path.init(alloc);
    defer path.deinit();

    const margin = 20;
    const x_scale = 3;
    const y_scale = 5;
    // With all 5 points numbered 1-5 clockwise, we draw odds first (1, 3, 5),
    // then evens (4, 2), with the close connecting 4 and 1.
    try path.moveTo(width / 2, 0 + margin); // 1
    try path.lineTo(width - margin * x_scale - 1, height - margin - 1); // 3
    try path.lineTo(0 + margin, 0 + margin * y_scale); // 5
    try path.lineTo(width - margin - 1, 0 + margin * y_scale); // 2
    try path.lineTo(0 + margin * x_scale, height - margin - 1); // 4
    try path.close();

    try context.stroke(alloc, path);

    return sfc;
}
