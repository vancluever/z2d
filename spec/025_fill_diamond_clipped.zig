//! Case: Renders and fills a diamond clipped on a 300x300 surface.
const debug = @import("std").debug;
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "025_fill_diamond_clipped";

pub fn render(alloc: mem.Allocator, aa_mode: z2d.options.AntiAliasMode) !z2d.Surface {
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
        .anti_aliasing_mode = aa_mode,
    };

    var path = z2d.Path.init(alloc);
    defer path.deinit();

    try path.moveTo(width / 2, 0 - height / 10);
    try path.lineTo(width + width / 10, height / 2);
    try path.lineTo(width / 2, height + height / 10);
    try path.lineTo(0 - width / 10, height / 2);
    try path.close();

    try context.fill(alloc, path);

    return sfc;
}
