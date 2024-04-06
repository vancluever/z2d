//! Case: Renders and fills multiple shapes using a single path operation, used
//! to ensure we can do this without having to fill each polygon individually.
const debug = @import("std").debug;
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "013_fill_combined";

pub fn render(alloc: mem.Allocator, aa_mode: z2d.AntiAliasMode) !z2d.Surface {
    const width = 600;
    const height = 400;
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

    // sub-canvas dimensions
    const sub_canvas_width = width / 3;
    const sub_canvas_height = height / 2;

    // Triangle
    comptime var margin = 10;
    try path.moveTo(.{ .x = 0 + margin, .y = 0 + margin });
    try path.lineTo(.{ .x = sub_canvas_width - margin - 1, .y = 0 + margin });
    try path.lineTo(.{ .x = sub_canvas_width / 2 - 1, .y = sub_canvas_height - margin - 1 });
    try path.closePath();

    // Square
    margin = 50;
    comptime var x_offset = sub_canvas_width;
    try path.moveTo(.{ .x = x_offset + margin, .y = 0 + margin });
    try path.lineTo(.{ .x = x_offset + sub_canvas_width - margin - 1, .y = 0 + margin });
    try path.lineTo(.{ .x = x_offset + sub_canvas_width - margin - 1, .y = sub_canvas_height - margin - 1 });
    try path.lineTo(.{ .x = x_offset + margin, .y = sub_canvas_height - margin - 1 });
    try path.closePath();

    // Trapezoid
    const trapezoid_margin_top = 59;
    const trapezoid_margin_bottom = 33;
    const trapezoid_margin_y = 66;
    x_offset = sub_canvas_width * 2;
    try path.moveTo(.{ .x = x_offset + trapezoid_margin_top, .y = 0 + trapezoid_margin_y });
    try path.lineTo(.{ .x = x_offset + sub_canvas_width - trapezoid_margin_top - 1, .y = 0 + trapezoid_margin_y });
    try path.lineTo(.{ .x = x_offset + sub_canvas_width - trapezoid_margin_bottom - 1, .y = sub_canvas_height - trapezoid_margin_y - 1 });
    try path.lineTo(.{ .x = x_offset + trapezoid_margin_bottom, .y = sub_canvas_height - trapezoid_margin_y - 1 });
    try path.closePath();

    // Star
    margin = 13;
    const x_scale = 3;
    const y_scale = 5;
    x_offset = width / 6;
    const y_offset = sub_canvas_height;
    // With all 5 points numbered 1-5 clockwise, we draw odds first (1, 3, 5),
    // then evens (4, 2), with the close connecting 4 and 1.
    try path.moveTo(.{ .x = x_offset + sub_canvas_width / 2, .y = y_offset + margin }); // 1
    try path.lineTo(.{ .x = x_offset + sub_canvas_width - margin * x_scale - 1, .y = y_offset + sub_canvas_height - margin - 1 }); // 3
    try path.lineTo(.{ .x = x_offset + margin, .y = y_offset + margin * y_scale }); // 5
    try path.lineTo(.{ .x = x_offset + sub_canvas_width - margin - 1, .y = y_offset + margin * y_scale }); // 2
    try path.lineTo(.{ .x = x_offset + margin * x_scale, .y = y_offset + sub_canvas_height - margin - 1 }); // 4
    try path.closePath();

    // Bezier
    x_offset += sub_canvas_width;
    const p0: z2d.Point = .{ .x = x_offset + 12, .y = y_offset + 166 };
    const p1: z2d.Point = .{ .x = x_offset + 59, .y = y_offset + 32 };
    const p2: z2d.Point = .{ .x = x_offset + 139, .y = y_offset + 32 };
    const p3: z2d.Point = .{ .x = x_offset + 186, .y = y_offset + 166 };
    try path.moveTo(p0);
    try path.curveTo(p1, p2, p3);
    try path.closePath();

    try context.fill(alloc, path);

    return sfc;
}
