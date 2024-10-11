// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024 Chris Marchesi
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
slope: Slope,
offset_x: f64,
offset_y: f64,
p0_cw: Point,
p0_ccw: Point,
p1_cw: Point,
p1_ccw: Point,
pen: Pen,
ctm: Transformation,

/// Computes a Face from two points in the direction of p0 -> p1.
pub fn init(p0: Point, p1: Point, thickness: f64, pen: Pen, ctm: Transformation) Face {
    const slope = Slope.init(p0, p1);
    const half_width = thickness / 2;
    var offset_x: f64 = undefined;
    var offset_y: f64 = undefined;
    if (!ctm.equal(Transformation.identity)) {
        // If we're transforming we need to transform our offsets for purposes
        // of correctly plotting joins and end cap points. Direction is mostly
        // already accounted for as our path is already assumed to be in device
        // space, but we need to warp our thickness and possibly reflect if the
        // ctm does that too.
        var dx = slope.dx;
        var dy = slope.dy;
        ctm.deviceToUserDistance(&dx, &dy) catch unreachable; // ctm should be validated before
        const slope_normalized = (Slope{ .dx = dx, .dy = dy }).normalize();
        const inv = math.sign(ctm.ax * ctm.dy - ctm.by * ctm.cx);
        offset_x = slope_normalized.dy * half_width * inv;
        offset_y = slope_normalized.dx * half_width * inv;
        ctm.userToDeviceDistance(&offset_x, &offset_y);
    } else {
        const factor = half_width / math.hypot(slope.dx, slope.dy);
        offset_x = slope.dy * factor;
        offset_y = slope.dx * factor;
    }

    return .{
        .p0 = p0,
        .p1 = p1,
        .width = thickness,
        .slope = slope,
        .offset_x = offset_x,
        .offset_y = offset_y,
        .p0_cw = .{ .x = p0.x - offset_x, .y = p0.y + offset_y },
        .p0_ccw = .{ .x = p0.x + offset_x, .y = p0.y - offset_y },
        .p1_cw = .{ .x = p1.x - offset_x, .y = p1.y + offset_y },
        .p1_ccw = .{ .x = p1.x + offset_x, .y = p1.y - offset_y },
        .pen = pen,
        .ctm = ctm,
    };
}

pub fn intersect(in: Face, out: Face, clockwise: bool) Point {
    debug.assert(in.slope.compare(out.slope) != 0);

    // Intersection taken from Cairo's miter join in
    // cairo-path-stroke-polygon.c et al.
    const in_point = if (clockwise) in.p1_ccw else in.p1_cw;
    const out_point = if (clockwise) out.p0_ccw else out.p0_cw;
    const in_slope = in.slope.normalize();
    const out_slope = out.slope.normalize();

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
) !void {
    const reversed = init(self.p1, self.p0, self.width, self.pen, self.ctm);
    return reversed.cap(
        plotter_impl,
        cap_mode,
        clockwise,
    );
}

pub fn cap_p1(
    self: Face,
    plotter_impl: *const PlotterVTable,
    cap_mode: options.CapMode,
    clockwise: bool,
) !void {
    return self.cap(
        plotter_impl,
        cap_mode,
        clockwise,
    );
}

fn cap(
    self: Face,
    plotter_impl: *const PlotterVTable,
    cap_mode: options.CapMode,
    clockwise: bool,
) !void {
    switch (cap_mode) {
        .butt => {
            try self.capButt(plotter_impl, clockwise);
        },
        .square => {
            try self.capSquare(plotter_impl, clockwise);
        },
        .round => {
            try self.capRound(plotter_impl, clockwise);
        },
    }
}

fn capButt(
    self: Face,
    plotter_impl: *const PlotterVTable,
    clockwise: bool,
) !void {
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
) !void {
    if (clockwise) {
        try plotter_impl.lineTo(.{ .point = self.p1_ccw });
        try plotter_impl.lineTo(.{ .point = .{
            .x = self.p1_ccw.x + self.offset_y,
            .y = self.p1_ccw.y + self.offset_x,
        } });
        try plotter_impl.lineTo(.{ .point = .{
            .x = self.p1_cw.x + self.offset_y,
            .y = self.p1_cw.y + self.offset_x,
        } });
        try plotter_impl.lineTo(.{ .point = self.p1_cw });
    } else {
        try plotter_impl.lineTo(.{ .point = self.p1_cw });
        try plotter_impl.lineTo(.{ .point = .{
            .x = self.p1_cw.x + self.offset_y,
            .y = self.p1_cw.y + self.offset_x,
        } });
        try plotter_impl.lineTo(.{ .point = .{
            .x = self.p1_ccw.x + self.offset_y,
            .y = self.p1_ccw.y + self.offset_x,
        } });
        try plotter_impl.lineTo(.{ .point = self.p1_ccw });
    }
}

fn capRound(
    self: Face,
    plotter_impl: *const PlotterVTable,
    clockwise: bool,
) !void {
    // We need to calculate our fan along the end as if we were
    // dealing with a 180 degree joint. So, treat it as if there
    // were two lines going in exactly opposite directions, i.e., flip the
    // incoming slope for the outgoing one.
    var vit = self.pen.vertexIteratorFor(
        self.slope,
        .{ .dx = -self.slope.dx, .dy = -self.slope.dy },
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
