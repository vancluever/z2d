// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024-2025 Chris Marchesi
//   Copyright © 2002 University of Southern California
//
// Portions of the code in this file (where mentioned) have been derived and
// adapted from the Cairo project (https://www.cairographics.org/), notably
// cairo-path-stroke-polygon.c.

//! A Face represents a hypothetically-computed polygon edge for a stroked
//! line.
//!
//! The face is computed from p0 -> p1 (see init). Interactions, such as
//! intersections, are specifically dictated by the orientation of any two
//! faces in relation to each other, when the faces are treated as segments
//! along the path, traveling in the same direction (e.g., p0 -> p1, p1 -> p2).
//!
//! For each face, its stroked endpoints, denoted by cw (clockwise) and ccw
//! (counter-clockwise) are taken by rotating a point 90 degrees in that
//! direction along the line, starting from p0 (or p1), to half of the line
//! thickness, in the same direction of the line (e.g., p0 -> p1).
const Face = @This();

const std = @import("std");
const debug = @import("std").debug;
const math = @import("std").math;
const mem = @import("std").mem;

const nodepkg = @import("path_nodes.zig");
const options = @import("../options.zig");

const Pen = @import("Pen.zig");
const Point = @import("Point.zig");
const Slope = @import("Slope.zig");
const PlotterVTable = @import("PlotterVTable.zig");
const Transformation = @import("../Transformation.zig");

p0: Point,
p1: Point,
width: f64,
dev_slope: Slope, // Device-space slope (normalized)
user_slope: Slope, // User-space slope (normalized)
half_width: f64, // Half-width of thickness on init
p0_cw: Point,
p0_ccw: Point,
p1_cw: Point,
p1_ccw: Point,
ctm: Transformation,

/// Computes a Face from two points in the direction of p0 -> p1.
pub fn init(p0: Point, p1: Point, thickness: f64, ctm: Transformation) Face {
    const dev_slope = dev_slope: {
        var s = Slope.init(p0, p1);
        _ = s.normalize();
        break :dev_slope s;
    };
    return _init(p0, p1, dev_slope, thickness, ctm);
}

/// Computes a face off a single point and (normalized) device slope.
pub fn initSingle(point: Point, dev_slope: Slope, thickness: f64, ctm: Transformation) Face {
    return _init(point, point, dev_slope, thickness, ctm);
}

/// Computes a Face from two points in the direction of p0 -> p1.
fn _init(p0: Point, p1: Point, dev_slope: Slope, thickness: f64, ctm: Transformation) Face {
    const half_width = thickness / 2;
    var offset_x: f64 = undefined;
    var offset_y: f64 = undefined;
    var user_slope = dev_slope;
    if (!ctm.equal(Transformation.identity)) {
        // If we're transforming we need to transform our offsets for purposes
        // of correctly plotting joins and end cap points. Direction is mostly
        // already accounted for as our path is already assumed to be in device
        // space, but we need to warp our thickness and possibly reflect if the
        // ctm does that too.
        var dx = dev_slope.dx;
        var dy = dev_slope.dy;
        ctm.deviceToUserDistance(&dx, &dy) catch unreachable; // ctm is pre-validated
        // Save user slope for future calcs
        user_slope = user_slope: {
            var s = Slope{ .dx = dx, .dy = dy };
            _ = s.normalize();
            break :user_slope s;
        };
        if (ctm.determinant() >= 0) {
            offset_x = -user_slope.dy * half_width;
            offset_y = user_slope.dx * half_width;
        } else {
            offset_x = user_slope.dy * half_width;
            offset_y = -user_slope.dx * half_width;
        }
        ctm.userToDeviceDistance(&offset_x, &offset_y);
    } else {
        offset_x = -dev_slope.dy * half_width;
        offset_y = dev_slope.dx * half_width;
    }
    const offset_cw_x = offset_x;
    const offset_cw_y = offset_y;
    const offset_ccw_x = -offset_cw_x;
    const offset_ccw_y = -offset_cw_y;

    return .{
        .p0 = p0,
        .p1 = p1,
        .width = thickness,
        .dev_slope = dev_slope,
        .user_slope = user_slope,
        .half_width = half_width,
        .p0_cw = .{ .x = p0.x + offset_cw_x, .y = p0.y + offset_cw_y },
        .p0_ccw = .{ .x = p0.x + offset_ccw_x, .y = p0.y + offset_ccw_y },
        .p1_cw = .{ .x = p1.x + offset_cw_x, .y = p1.y + offset_cw_y },
        .p1_ccw = .{ .x = p1.x + offset_ccw_x, .y = p1.y + offset_ccw_y },
        .ctm = ctm,
    };
}

pub fn intersect(in: Face, out: Face, clockwise: bool) Point {
    debug.assert(in.dev_slope.compare(out.dev_slope) != 0);

    // Intersection taken from Cairo's miter join in
    // cairo-path-stroke-polygon.c et al.
    const in_point = if (clockwise) in.p1_ccw else in.p1_cw;
    const out_point = if (clockwise) out.p0_ccw else out.p0_cw;
    // Normalize our slopes, if not done already.
    //
    // TODO: This can probably be taken out. We never *not* normalize slopes
    // anymore, so if this is particularly costly it probably be removed (in
    // favor of setting the expectation that we always expect normalized slopes
    // here).
    const in_slope = in_normal: {
        var s = in.dev_slope;
        _ = s.normalize();
        break :in_normal s;
    };
    const out_slope = out_normal: {
        var s = out.dev_slope;
        _ = s.normalize();
        break :out_normal s;
    };

    const result_y = ((out_point.x - in_point.x) * in_slope.dy * out_slope.dy - out_point.y * out_slope.dx * in_slope.dy + in_point.y * in_slope.dx * out_slope.dy) / (in_slope.dx * out_slope.dy - out_slope.dx * in_slope.dy);

    const result_x = if (@abs(in_slope.dy) >= @abs(out_slope.dy))
        (result_y - in_point.y) * in_slope.dx / in_slope.dy + in_point.x
    else
        (result_y - out_point.y) * out_slope.dx / out_slope.dy + out_point.x;

    return .{
        .x = result_x,
        .y = result_y,
    };
}

pub fn cap_p0(
    self: Face,
    plotter_impl: *const PlotterVTable,
    cap_mode: options.CapMode,
    clockwise: bool,
    pen: ?Pen,
) PlotterVTable.Error!void {
    const reversed = init(self.p1, self.p0, self.width, self.ctm);
    return reversed.cap(
        plotter_impl,
        cap_mode,
        clockwise,
        pen,
    );
}

pub fn cap_p1(
    self: Face,
    plotter_impl: *const PlotterVTable,
    cap_mode: options.CapMode,
    clockwise: bool,
    pen: ?Pen,
) PlotterVTable.Error!void {
    return self.cap(
        plotter_impl,
        cap_mode,
        clockwise,
        pen,
    );
}

fn cap(
    self: Face,
    plotter_impl: *const PlotterVTable,
    cap_mode: options.CapMode,
    clockwise: bool,
    pen: ?Pen,
) PlotterVTable.Error!void {
    switch (cap_mode) {
        .butt => {
            try self.capButt(plotter_impl, clockwise);
        },
        .square => {
            try self.capSquare(plotter_impl, clockwise);
        },
        .round => {
            try self.capRound(plotter_impl, clockwise, pen);
        },
    }
}

fn capButt(
    self: Face,
    plotter_impl: *const PlotterVTable,
    clockwise: bool,
) PlotterVTable.Error!void {
    if (clockwise) {
        try plotter_impl.lineTo(.{ .point = self.p1_ccw });
        try plotter_impl.lineTo(.{ .point = self.p1_cw });
    } else {
        try plotter_impl.lineTo(.{ .point = self.p1_cw });
        try plotter_impl.lineTo(.{ .point = self.p1_ccw });
    }
}

fn capSquare(
    self: Face,
    plotter_impl: *const PlotterVTable,
    clockwise: bool,
) PlotterVTable.Error!void {
    var offset_x = self.user_slope.dx * self.half_width;
    var offset_y = self.user_slope.dy * self.half_width;
    self.ctm.userToDeviceDistance(&offset_x, &offset_y);
    if (clockwise) {
        try plotter_impl.lineTo(.{ .point = self.p1_ccw });
        try plotter_impl.lineTo(.{ .point = .{
            .x = self.p1_ccw.x + offset_x,
            .y = self.p1_ccw.y + offset_y,
        } });
        try plotter_impl.lineTo(.{ .point = .{
            .x = self.p1_cw.x + offset_x,
            .y = self.p1_cw.y + offset_y,
        } });
        try plotter_impl.lineTo(.{ .point = self.p1_cw });
    } else {
        try plotter_impl.lineTo(.{ .point = self.p1_cw });
        try plotter_impl.lineTo(.{ .point = .{
            .x = self.p1_cw.x + offset_x,
            .y = self.p1_cw.y + offset_y,
        } });
        try plotter_impl.lineTo(.{ .point = .{
            .x = self.p1_ccw.x + offset_x,
            .y = self.p1_ccw.y + offset_y,
        } });
        try plotter_impl.lineTo(.{ .point = self.p1_ccw });
    }
}

fn capRound(
    self: Face,
    plotter_impl: *const PlotterVTable,
    clockwise: bool,
    pen: ?Pen,
) PlotterVTable.Error!void {
    // We need to calculate our fan along the end as if we were
    // dealing with a 180 degree joint. So, treat it as if there
    // were two lines going in exactly opposite directions, i.e., flip the
    // incoming slope for the outgoing one.
    debug.assert(pen != null);
    var vit = pen.?.vertexIteratorFor(
        self.dev_slope,
        .{ .dx = -self.dev_slope.dx, .dy = -self.dev_slope.dy },
        clockwise,
    );
    if (clockwise) {
        try plotter_impl.lineTo(.{ .point = self.p1_ccw });
    } else {
        try plotter_impl.lineTo(.{ .point = self.p1_cw });
    }
    while (vit.next()) |v| {
        try plotter_impl.lineTo(.{ .point = .{
            .x = self.p1.x + v.point.x,
            .y = self.p1.y + v.point.y,
        } });
    }
    if (clockwise) {
        try plotter_impl.lineTo(.{ .point = self.p1_cw });
    } else {
        try plotter_impl.lineTo(.{ .point = self.p1_ccw });
    }
}
