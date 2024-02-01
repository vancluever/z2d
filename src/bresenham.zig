// The following functions perform line drawing using the Bresenham algorithm,
// as seen in "Algorithm for computer control of a digital plotter" (Bresenham,
// 1965), and countless citations since.
//
// The code here has been derived from the examples on the Wikipedia page, see
// "Derivation -> All cases":
//   https://en.wikipedia.org/w/index.php?title=Bresenham%27s_line_algorithm&oldid=1199948423
//
// And is used under the conditions of the Creative Commons Attribution
// Share-Alike License 4.0, seen at:
//   https://en.wikipedia.org/wiki/Wikipedia:Text_of_the_Creative_Commons_Attribution-ShareAlike_4.0_International_License#License

const Point = @import("path.zig").Point;
const DrawContext = @import("context.zig").DrawContext;

/// Draw a line using the Bresenham algorithm for a standard slope
/// ( -1 <= m <= 1); iterates along the X axis.
pub fn drawIterX(context: *DrawContext, p0: Point, p1: Point) !void {
    const delta_x: i32 = @intFromFloat(p1.x - p0.x);
    var delta_y: i32 = @intFromFloat(p1.y - p0.y);
    var y_increment: i32 = 1;
    if (delta_y < 0) {
        y_increment = -1;
        delta_y = -delta_y;
    }

    const start_x: usize = @intFromFloat(p0.x);
    const end_x: usize = @intFromFloat(p1.x);
    var y: i32 = @intFromFloat(p0.y);
    var d = (2 * delta_y) - delta_x;

    for (start_x..end_x + 1) |x| {
        try drawPixel(context, @intCast(x), @intCast(y));
        if (d > 0) {
            y += y_increment;
            d += 2 * (delta_y - delta_x);
        } else {
            d += 2 * delta_y;
        }
    }
}

/// Draw a line using the Bresenham algorithm for a steep slope
/// ( -1 > m > 1); iterates along the Y axis.
pub fn drawIterY(context: *DrawContext, p0: Point, p1: Point) !void {
    var delta_x: i32 = @intFromFloat(p1.x - p0.x);
    const delta_y: i32 = @intFromFloat(p1.y - p0.y);
    var x_increment: i32 = 1;
    if (delta_x < 0) {
        x_increment = -1;
        delta_x = -delta_x;
    }

    const start_y: usize = @intFromFloat(p0.y);
    const end_y: usize = @intFromFloat(p1.y);
    var x: i32 = @intFromFloat(p0.x);
    var d = (2 * delta_x) - delta_y;

    for (start_y..end_y + 1) |y| {
        try drawPixel(context, @intCast(x), @intCast(y));
        if (d > 0) {
            x += x_increment;
            d += 2 * (delta_x - delta_y);
        } else {
            d += 2 * delta_x;
        }
    }
}

fn drawPixel(context: *DrawContext, x: u32, y: u32) !void {
    const pixel = try context.pattern.getPixel(x, y);
    try context.surface.putPixel(x, y, pixel);
}
