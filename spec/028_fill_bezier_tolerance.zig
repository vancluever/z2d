//! Case: Renders and fills bezier curves on a 900x300 surface at varying
//! levels of error tolerance.
const debug = @import("std").debug;
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "028_fill_bezier_tolerance";

pub fn render(alloc: mem.Allocator, aa_mode: z2d.options.AntiAliasMode) !z2d.Surface {
    const width = 900;
    const height = 300;
    const sfc = try z2d.Surface.init(.image_surface_rgb, alloc, width, height);

    var context: z2d.Context = .{
        .surface = sfc,
        .pattern = .{
            .opaque_pattern = .{
                .pixel = .{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } }, // White on black
            },
        },
        .anti_aliasing_mode = aa_mode,
    };

    var path = z2d.Path.init(alloc);
    defer path.deinit();
    context.line_width = 5;

    try path.moveTo(19, 224);
    try path.curveTo(89, 49, 209, 49, 279, 224);
    try path.close();
    try context.fill(alloc, path);

    context.tolerance = 3;
    path.reset();
    try path.moveTo(319, 224);
    try path.curveTo(389, 49, 509, 49, 579, 224);
    try path.close();
    try context.fill(alloc, path);

    context.tolerance = 10;
    path.reset();
    try path.moveTo(619, 224);
    try path.curveTo(689, 49, 809, 49, 879, 224);
    try path.close();
    try context.fill(alloc, path);

    return sfc;
}
