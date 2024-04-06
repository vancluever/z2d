//! Case: Renders and fills a bezier curve on a 300x300 surface.
const debug = @import("std").debug;
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "007_fill_bezier";

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
        .anti_aliasing_mode = aa_mode,
    };

    var path = z2d.PathOperation.init(alloc);
    defer path.deinit();

    const p0: z2d.Point = .{ .x = 19, .y = 249 };
    const p1: z2d.Point = .{ .x = 89, .y = 49 };
    const p2: z2d.Point = .{ .x = 209, .y = 49 };
    const p3: z2d.Point = .{ .x = 279, .y = 249 };
    try path.moveTo(p0);
    try path.curveTo(p1, p2, p3);
    try path.closePath();

    try context.fill(alloc, path);

    return sfc;
}
