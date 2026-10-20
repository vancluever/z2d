// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024-2026 Chris Marchesi

//! An interface for the path builder. Used by arc methods to deconstruct said
//! operations into spline instructions.
const PathVTable = @This();

const std = @import("std");

pub const Error = @import("../Path.zig").Error || std.mem.Allocator.Error;

ptr: *anyopaque,
alloc: std.mem.Allocator,
line_to: *const fn (
    ctx: *anyopaque,
    alloc: std.mem.Allocator,
    err_: *?std.mem.Allocator.Error,
    x: f64,
    y: f64,
) void,

curve_to: *const fn (
    ctx: *anyopaque,
    alloc: std.mem.Allocator,
    err_: *?Error,
    x1: f64,
    y1: f64,
    x2: f64,
    y2: f64,
    x3: f64,
    y3: f64,
) void,

pub fn lineTo(self: *const PathVTable, x: f64, y: f64) std.mem.Allocator.Error!void {
    var err_: ?std.mem.Allocator.Error = null;
    self.line_to(self.ptr, self.alloc, &err_, x, y);
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
) Error!void {
    var err_: ?Error = null;
    self.curve_to(self.ptr, self.alloc, &err_, x1, y1, x2, y2, x3, y3);
    if (err_) |err| return err;
}
