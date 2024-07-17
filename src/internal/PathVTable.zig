// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024 Chris Marchesi

//! An interface for the path builder. Used by arc methods to deconstruct said
//! operations into spline instructions.
const PathVTable = @This();

ptr: *anyopaque,
line_to: *const fn (ctx: *anyopaque, err_: *?anyerror, x: f64, y: f64) void,
curve_to: *const fn (
    ctx: *anyopaque,
    err_: *?anyerror,
    x1: f64,
    y1: f64,
    x2: f64,
    y2: f64,
    x3: f64,
    y3: f64,
) void,

pub fn lineTo(self: *const PathVTable, x: f64, y: f64) !void {
    var err_: ?anyerror = null;
    self.line_to(self.ptr, &err_, x, y);
    if (err_) |err| return err;
}

pub fn curveTo(
    self: *const PathVTable,
    x1: f64,
    y1: f64,
    x2: f64,
    y2: f64,
    x3: f64,
    y3: f64,
) !void {
    var err_: ?anyerror = null;
    self.curve_to(self.ptr, &err_, x1, y1, x2, y2, x3, y3);
    if (err_) |err| return err;
}
