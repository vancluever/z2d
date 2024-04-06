//! Case: Renders multiple lines, butt-capped, in various directions.
const debug = @import("std").debug;
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "022_stroke_lines_butt_caps";

pub fn render(alloc: mem.Allocator, aa_mode: z2d.AntiAliasMode) !z2d.Surface {
    const width = 800;
    const height = 600;
    const sfc = try z2d.Surface.init(.image_surface_rgb, alloc, width, height);

    var context: z2d.Context = .{
        .surface = sfc,
        .pattern = .{
            .opaque_pattern = .{
                .pixel = .{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } }, // White on black
            },
        },
        .line_cap_mode = .butt,
        .line_width = 20,
        .anti_aliasing_mode = aa_mode,
    };

    var path = z2d.Path.init(alloc);
    defer path.deinit();

    // sub-canvas dimensions
    const sub_canvas_width = width / 4;
    var sub_canvas_height: f64 = height / 3;

    // Down and to the right
    const margin = 30;
    var x_offset: f64 = 0;
    var y_offset: f64 = 0;
    try path.moveTo(.{
        .x = x_offset + margin,
        .y = y_offset + margin,
    });
    try path.lineTo(.{
        .x = x_offset + sub_canvas_width - margin - 1,
        .y = y_offset + sub_canvas_height - margin - 1,
    });

    // Up and to the right
    x_offset = sub_canvas_width;
    try path.moveTo(.{
        .x = x_offset + margin,
        .y = y_offset + sub_canvas_height - margin - 1,
    });
    try path.lineTo(.{
        .x = x_offset + sub_canvas_width - margin - 1,
        .y = y_offset + margin,
    });

    // Down and to the left
    x_offset = 0;
    y_offset = sub_canvas_height;
    try path.moveTo(.{
        .x = x_offset + sub_canvas_width - margin - 1,
        .y = y_offset + margin,
    });
    try path.lineTo(.{
        .x = x_offset + margin,
        .y = y_offset + sub_canvas_height - margin - 1,
    });

    // Up and to the left
    x_offset = sub_canvas_width;
    y_offset = sub_canvas_height;
    try path.moveTo(.{
        .x = x_offset + sub_canvas_width - margin - 1,
        .y = y_offset + sub_canvas_height - margin - 1,
    });
    try path.lineTo(.{
        .x = x_offset + margin,
        .y = y_offset + margin,
    });

    // Horizontal (left -> right)
    x_offset = sub_canvas_width * 2;
    y_offset = 0;
    try path.moveTo(.{
        .x = x_offset + margin,
        .y = y_offset + sub_canvas_height / 2,
    });
    try path.lineTo(.{
        .x = x_offset + sub_canvas_width - margin - 1,
        .y = y_offset + sub_canvas_height / 2,
    });

    // Vertical (up -> down)
    x_offset = sub_canvas_width * 2;
    y_offset = sub_canvas_height;
    try path.moveTo(.{
        .x = x_offset + sub_canvas_width / 2,
        .y = y_offset + margin,
    });
    try path.lineTo(.{
        .x = x_offset + sub_canvas_width / 2,
        .y = y_offset + sub_canvas_height - margin - 1,
    });

    // Vertical (down -> up)
    x_offset = sub_canvas_width * 3;
    y_offset = 0;
    try path.moveTo(.{
        .x = x_offset + sub_canvas_width / 2,
        .y = y_offset + sub_canvas_height - margin - 1,
    });
    try path.lineTo(.{
        .x = x_offset + sub_canvas_width / 2,
        .y = y_offset + margin,
    });

    // Horizontal (right -> left)
    x_offset = sub_canvas_width * 3;
    y_offset = sub_canvas_height;
    try path.moveTo(.{
        .x = x_offset + sub_canvas_width - margin - 1,
        .y = y_offset + sub_canvas_height / 2,
    });
    try path.lineTo(.{
        .x = x_offset + margin,
        .y = y_offset + sub_canvas_height / 2,
    });

    // Joined, clockwise
    x_offset = 0;
    y_offset = sub_canvas_height * 2;
    try path.moveTo(.{
        .x = x_offset + margin,
        .y = y_offset + margin,
    });
    try path.lineTo(.{
        .x = x_offset + sub_canvas_width - margin - 1,
        .y = y_offset + sub_canvas_height / 2 - 1,
    });
    try path.lineTo(.{
        .x = x_offset + margin,
        .y = y_offset + sub_canvas_height - margin - 1,
    });

    // Joined, counter-clockwise
    x_offset = sub_canvas_width;
    try path.moveTo(.{
        .x = x_offset + sub_canvas_width - margin - 1,
        .y = y_offset + margin,
    });
    try path.lineTo(.{
        .x = x_offset + margin,
        .y = y_offset + sub_canvas_height / 2 - 1,
    });
    try path.lineTo(.{
        .x = x_offset + sub_canvas_width - margin - 1,
        .y = y_offset + sub_canvas_height - margin - 1,
    });

    // Joined, clockwise up-down, down-up
    x_offset = sub_canvas_width * 2;
    sub_canvas_height = sub_canvas_height / 2;
    try path.moveTo(.{
        .x = x_offset + margin,
        .y = y_offset + margin,
    });
    try path.lineTo(.{
        .x = x_offset + sub_canvas_width / 2 - 1,
        .y = y_offset + sub_canvas_height - margin - 1,
    });
    try path.lineTo(.{
        .x = x_offset + sub_canvas_width - margin - 1,
        .y = y_offset + margin,
    });

    // Joined, clockwise down-up, up-down
    x_offset = sub_canvas_width * 3;
    try path.moveTo(.{
        .x = x_offset + margin,
        .y = y_offset + sub_canvas_height - margin - 1,
    });
    try path.lineTo(.{
        .x = x_offset + sub_canvas_width / 2 - 1,
        .y = y_offset + margin,
    });
    try path.lineTo(.{
        .x = x_offset + sub_canvas_width - margin - 1,
        .y = y_offset + sub_canvas_height - margin - 1,
    });

    // Joined, counter-clockwise, down-up, up-down
    x_offset = sub_canvas_width * 2;
    y_offset = y_offset + sub_canvas_height;
    try path.moveTo(.{
        .x = x_offset + sub_canvas_width - margin - 1,
        .y = y_offset + sub_canvas_height - margin - 1,
    });
    try path.lineTo(.{
        .x = x_offset + sub_canvas_width / 2 - 1,
        .y = y_offset + margin,
    });
    try path.lineTo(.{
        .x = x_offset + margin,
        .y = y_offset + sub_canvas_height - margin - 1,
    });

    // Joined, counter-clockwise, up-down, down-up
    x_offset = sub_canvas_width * 3;
    try path.moveTo(.{
        .x = x_offset + sub_canvas_width - margin - 1,
        .y = y_offset + margin,
    });
    try path.lineTo(.{
        .x = x_offset + sub_canvas_width / 2 - 1,
        .y = y_offset + sub_canvas_height - margin - 1,
    });
    try path.lineTo(.{
        .x = x_offset + margin,
        .y = y_offset + margin,
    });

    try context.stroke(alloc, path);

    // We draw a hairline in the same path in red - this validates how the caps
    // and joins are aligned.
    context.pattern.opaque_pattern.pixel = .{ .rgb = .{ .r = 0xF3, .g = 0x00, .b = 0x00 } }; // Red
    context.line_width = 1;

    try context.stroke(alloc, path);

    return sfc;
}
