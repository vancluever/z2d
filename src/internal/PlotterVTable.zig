//! An interface for plotting lines on a polygon, used by some of our drawing
//! implementations (e.g., spline deconstruction, line capping).
const PlotterVTable = @This();
const nodepkg = @import("path_nodes.zig");

ptr: *anyopaque,
line_to: *const fn (ctx: *anyopaque, err_: *?anyerror, node: nodepkg.PathLineTo) void,

pub fn lineTo(self: *const PlotterVTable, node: nodepkg.PathLineTo) !void {
    var err_: ?anyerror = null;
    self.line_to(self.ptr, &err_, node);
    if (err_) |err| return err;
}
