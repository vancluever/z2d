// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024-2025 Chris Marchesi

//! An interface for plotting lines on a polygon, used by some of our drawing
//! implementations (e.g., spline deconstruction, line capping).
const PlotterVTable = @This();

const mem = @import("std").mem;

const nodepkg = @import("path_nodes.zig");

const InternalError = @import("InternalError.zig").InternalError;

pub const Error = InternalError || mem.Allocator.Error;

ptr: *anyopaque,
line_to: *const fn (ctx: *anyopaque, err_: *?Error, node: nodepkg.PathLineTo) void,

pub fn lineTo(self: *const PlotterVTable, node: nodepkg.PathLineTo) Error!void {
    var err_: ?Error = null;
    self.line_to(self.ptr, &err_, node);
    if (err_) |err| return err;
}
