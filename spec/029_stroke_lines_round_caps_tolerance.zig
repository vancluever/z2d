//! Case: Renders multiple lines, round-capped at varying levels of tolerance.
const debug = @import("std").debug;
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "029_stroke_lines_round_caps_tolerance";

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
        .line_cap_mode = .round,
        .line_join_mode = .round,
        .line_width = 30,
        .anti_aliasing_mode = aa_mode,
    };

    var path = z2d.Path.init(alloc);
    defer path.deinit();

    try path.moveTo(30, 50);
    try path.lineTo(270, 50);
    try context.stroke(alloc, path);

    context.tolerance = 3;
    path.reset();
    try path.moveTo(30, 150);
    try path.lineTo(270, 150);
    try context.stroke(alloc, path);

    context.tolerance = 10;
    path.reset();
    try path.moveTo(30, 250);
    try path.lineTo(270, 250);
    try context.stroke(alloc, path);

    return sfc;
}
