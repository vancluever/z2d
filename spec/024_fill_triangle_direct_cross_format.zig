//! Case: Renders and fills a triangle on a 300x300 surface, but with different
//! pixel types (RGBA on RGB surface) We expect compositing to work on both
//! main AA modes (no AA, default AA).
const debug = @import("std").debug;
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "024_fill_triangle_direct_cross_format";

pub fn render(alloc: mem.Allocator, aa_mode: z2d.AntiAliasMode) !z2d.Surface {
    const width = 300;
    const height = 300;
    const sfc = try z2d.Surface.init(.image_surface_rgb, alloc, width, height);

    var context: z2d.Context = .{
        .surface = sfc,
        .pattern = .{
            .opaque_pattern = .{
                .pixel = .{ .rgba = .{ .r = 0xFF, .g = 0x8a, .b = 0xa5, .a = 0xFF } }, // Bubblegum!
            },
        },
        .anti_aliasing_mode = aa_mode,
    };

    var path = z2d.Path.init(alloc);
    defer path.deinit();

    const margin = 10;
    try path.moveTo(.{ .x = 0 + margin, .y = 0 + margin });
    try path.lineTo(.{ .x = width - margin - 1, .y = 0 + margin });
    try path.lineTo(.{ .x = width / 2 - 1, .y = height - margin - 1 });
    try path.close();

    try context.fill(alloc, path);

    return sfc;
}
